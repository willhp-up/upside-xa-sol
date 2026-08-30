const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Upside Xa v2.0 — Full Test Suite", function () {
  let token, issuance, burn, staking, treasury, governance;
  let admin, oracle, alice, bob, carol;
  const ONE_UPC = ethers.parseUnits("1", 18);
  const HUNDRED_UPC = ethers.parseUnits("100", 18);
  const THOUSAND_UPC = ethers.parseUnits("1000", 18);

  beforeEach(async function () {
    [admin, oracle, alice, bob, carol] = await ethers.getSigners();

    // Deploy all contracts
    const Token = await ethers.getContractFactory("UpsideToken");
    token = await Token.deploy();

    const Issuance = await ethers.getContractFactory("RewardIssuance");
    issuance = await Issuance.deploy();

    const Burn = await ethers.getContractFactory("BurnMechanism");
    burn = await Burn.deploy();

    const Staking = await ethers.getContractFactory("IdeaStaking");
    staking = await Staking.deploy();

    const Treasury = await ethers.getContractFactory("Treasury");
    treasury = await Treasury.deploy(admin.address, alice.address, bob.address);

    const Governance = await ethers.getContractFactory("Governance");
    governance = await Governance.deploy();

    // Wire everything
    await token.setIssuanceContract(await issuance.getAddress());
    await token.setBurnContract(await burn.getAddress());
    await token.setGovernanceContract(await governance.getAddress());

    await issuance.setTokenContract(await token.getAddress());
    await issuance.setGovernanceContract(await governance.getAddress());

    await burn.setTokenContract(await token.getAddress());
    await burn.setGovernanceContract(await governance.getAddress());

    await staking.setTokenContract(await token.getAddress());
    await staking.setGovernanceContract(await governance.getAddress());

    await treasury.setGovernanceContract(await governance.getAddress());

    await governance.registerContracts(
      await token.getAddress(),
      await issuance.getAddress(),
      await burn.getAddress(),
      await treasury.getAddress(),
      await staking.getAddress()
    );

    // Set oracle via governance
    await governance.setOracle(oracle.address);
  });

  // ════════════════════════════════════════════════════════════════════════
  // UpsideToken
  // ════════════════════════════════════════════════════════════════════════

  describe("UpsideToken", function () {
    it("T1: deploys with zero supply and correct metadata", async function () {
      expect(await token.name()).to.equal("Upside Xa");
      expect(await token.symbol()).to.equal("UPC");
      expect(await token.decimals()).to.equal(18);
      expect(await token.totalSupply()).to.equal(0);
    });

    it("T2: admin can mint reserve tokens (no lock)", async function () {
      await token.mintReserve(alice.address, THOUSAND_UPC);
      expect(await token.balanceOf(alice.address)).to.equal(THOUSAND_UPC);
      expect(await token.availableBalanceOf(alice.address)).to.equal(THOUSAND_UPC);
      expect(await token.lockedBalanceOf(alice.address)).to.equal(0);
    });

    it("T3: issuance contract can mint with lock", async function () {
      await issuance.connect(admin).createPeriod(THOUSAND_UPC, 1, 9999999999);
      await issuance.connect(oracle).submitScore(1, alice.address, 1, 500);
      await issuance.connect(admin).finalizePeriod(1);
      await issuance.connect(alice).claimReward(1);

      const balance = await token.balanceOf(alice.address);
      expect(balance).to.be.gt(0);
      // Locked — not available yet
      expect(await token.lockedBalanceOf(alice.address)).to.equal(balance);
      expect(await token.availableBalanceOf(alice.address)).to.equal(0);
    });

    it("T4: transfers only from available balance", async function () {
      await token.mintReserve(alice.address, HUNDRED_UPC);
      await token.connect(alice).transfer(bob.address, ethers.parseUnits("50", 18));
      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseUnits("50", 18));
      expect(await token.balanceOf(bob.address)).to.equal(ethers.parseUnits("50", 18));
    });

    it("T5: cannot transfer more than available", async function () {
      await token.mintReserve(alice.address, HUNDRED_UPC);
      await expect(
        token.connect(alice).transfer(bob.address, ethers.parseUnits("101", 18))
      ).to.be.revertedWith("Insufficient available balance");
    });

    it("T6: cannot exceed supply cap", async function () {
      const maxSupply = ethers.parseUnits("5000000", 18);
      await expect(
        token.mintReserve(alice.address, maxSupply + 1n)
      ).to.be.revertedWith("Supply cap exceeded");
    });

    it("T7: admin can burn tokens (for decay)", async function () {
      await token.mintReserve(alice.address, HUNDRED_UPC);
      await token.adminBurn(alice.address, ethers.parseUnits("30", 18));
      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseUnits("70", 18));
      expect(await token.totalSupply()).to.equal(ethers.parseUnits("70", 18));
    });

    it("T8: non-admin cannot mint or admin-burn", async function () {
      await expect(
        token.connect(alice).mintReserve(alice.address, HUNDRED_UPC)
      ).to.be.revertedWith("Not admin");
      await expect(
        token.connect(alice).adminBurn(bob.address, ONE_UPC)
      ).to.be.revertedWith("Not admin or burn contract");
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // RewardIssuance
  // ════════════════════════════════════════════════════════════════════════

  describe("RewardIssuance", function () {
    it("T9: full period lifecycle — create, score, finalize, claim", async function () {
      const allocation = ethers.parseUnits("10000", 18);
      await issuance.createPeriod(allocation, 1, 9999999999);

      // Oracle submits scores
      await issuance.connect(oracle).submitScore(1, alice.address, 1, 700);
      await issuance.connect(oracle).submitScore(1, bob.address, 2, 300);

      const period = await issuance.getPeriod(1);
      expect(period.participantCount).to.equal(2);
      expect(period.totalScore).to.equal(1000);

      await issuance.finalizePeriod(1);

      // Alice claims: 700/1000 * 10000 = 7000 UPC
      await issuance.connect(alice).claimReward(1);
      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseUnits("7000", 18));

      // Bob claims: 300/1000 * 10000 = 3000 UPC
      await issuance.connect(bob).claimReward(1);
      expect(await token.balanceOf(bob.address)).to.equal(ethers.parseUnits("3000", 18));
    });

    it("T10: cannot double-claim", async function () {
      await issuance.createPeriod(THOUSAND_UPC, 1, 9999999999);
      await issuance.connect(oracle).submitScore(1, alice.address, 1, 500);
      await issuance.finalizePeriod(1);
      await issuance.connect(alice).claimReward(1);
      await expect(
        issuance.connect(alice).claimReward(1)
      ).to.be.revertedWith("Already claimed");
    });

    it("T11: batch score submission", async function () {
      await issuance.createPeriod(THOUSAND_UPC, 1, 9999999999);
      await issuance.connect(oracle).submitScoresBatch(
        1,
        [alice.address, bob.address, carol.address],
        [1, 2, 3],
        [400, 300, 300]
      );
      expect(await issuance.getUserScore(1, alice.address)).to.equal(400);
      expect(await issuance.getUserScore(1, bob.address)).to.equal(300);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // BurnMechanism
  // ════════════════════════════════════════════════════════════════════════

  describe("BurnMechanism", function () {
    beforeEach(async function () {
      // Give users tokens to burn
      await token.mintReserve(alice.address, THOUSAND_UPC);
      await token.mintReserve(bob.address, THOUSAND_UPC);
    });

    it("T12: voluntary burn lifecycle", async function () {
      const now = Math.floor(Date.now() / 1000);
      await burn.createBurnEvent(ethers.parseEther("1"), now - 100, now + 86400);
      await burn.openBurnEvent(1);

      // Alice burns 100 UPC (10% of 1000, under 25% cap)
      await burn.connect(alice).burnTokens(1, HUNDRED_UPC);
      expect(await burn.getUserBurn(1, alice.address)).to.equal(HUNDRED_UPC);
      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseUnits("900", 18));

      await burn.closeBurnEvent(1);
      const evt = await burn.getBurnEvent(1);
      expect(evt.status).to.equal(3); // Completed
    });

    it("T13: enforces 25% burn cap", async function () {
      const now = Math.floor(Date.now() / 1000);
      await burn.createBurnEvent(ethers.parseEther("1"), now - 100, now + 86400);
      await burn.openBurnEvent(1);

      const tooMuch = ethers.parseUnits("260", 18); // 26% of 1000
      await expect(
        burn.connect(alice).burnTokens(1, tooMuch)
      ).to.be.revertedWith("Exceeds 25% burn cap");
    });

    it("T14: decay burn — admin burns inactive user tokens", async function () {
      await burn.decayBurn(alice.address, ethers.parseUnits("50", 18), 9);
      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseUnits("950", 18));
      expect(await burn.getUserDecayBurned(alice.address)).to.equal(ethers.parseUnits("50", 18));

      const [voluntary, decay, total, count] = await burn.burnSummary();
      expect(decay).to.equal(ethers.parseUnits("50", 18));
      expect(count).to.equal(1);
    });

    it("T15: batch decay burn", async function () {
      await burn.decayBurnBatch(
        [alice.address, bob.address],
        [ethers.parseUnits("30", 18), ethers.parseUnits("20", 18)],
        [10, 11]
      );
      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseUnits("970", 18));
      expect(await token.balanceOf(bob.address)).to.equal(ethers.parseUnits("980", 18));

      const [, , , count] = await burn.burnSummary();
      expect(count).to.equal(2);
    });

    it("T16: non-admin cannot decay burn", async function () {
      await expect(
        burn.connect(alice).decayBurn(bob.address, ONE_UPC, 9)
      ).to.be.revertedWith("Not admin");
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // IdeaStaking
  // ════════════════════════════════════════════════════════════════════════

  describe("IdeaStaking", function () {
    beforeEach(async function () {
      await token.mintReserve(alice.address, THOUSAND_UPC);
      await token.mintReserve(bob.address, THOUSAND_UPC);
      // Users must approve staking contract to spend their tokens
      await token.connect(alice).approve(await staking.getAddress(), ethers.MaxUint256);
      await token.connect(bob).approve(await staking.getAddress(), ethers.MaxUint256);
    });

    it("T17: record self-stake", async function () {
      await staking.connect(oracle).recordStake(alice.address, 1, 0, ethers.parseUnits("50", 18));

      const stake = await staking.getStake(1);
      expect(stake.user).to.equal(alice.address);
      expect(stake.ideaId).to.equal(1);
      expect(stake.stakeType).to.equal(0); // Self
      expect(stake.amount).to.equal(ethers.parseUnits("50", 18));
      expect(stake.status).to.equal(0); // Active

      // Tokens moved from alice to staking contract
      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseUnits("950", 18));
    });

    it("T18: record endorsement", async function () {
      await staking.connect(oracle).recordStake(bob.address, 1, 1, ethers.parseUnits("20", 18));

      const stake = await staking.getStake(1);
      expect(stake.stakeType).to.equal(1); // Endorsement
      expect(await token.balanceOf(bob.address)).to.equal(ethers.parseUnits("980", 18));
    });

    it("T19: settle winning stake — returns tokens", async function () {
      await staking.connect(oracle).recordStake(alice.address, 1, 0, ethers.parseUnits("50", 18));

      // Settle as win (reward minted separately off-chain)
      await staking.connect(oracle).settleWin(1, ethers.parseUnits("5", 18));

      const stake = await staking.getStake(1);
      expect(stake.status).to.equal(2); // Settled

      // Alice gets her 50 UPC back
      expect(await token.balanceOf(alice.address)).to.equal(THOUSAND_UPC);
    });

    it("T20: settle losing stake — burns portion", async function () {
      await staking.connect(oracle).recordStake(alice.address, 1, 0, ethers.parseUnits("100", 18));

      // 70% slash: 70 burned, 30 returned (no treasury portion for simplicity)
      await staking.connect(oracle).settleLoss(1, ethers.parseUnits("70", 18), 0);

      const stake = await staking.getStake(1);
      expect(stake.status).to.equal(3); // Slashed
      expect(stake.burnAmount).to.equal(ethers.parseUnits("70", 18));

      // Alice gets back 30 UPC (900 + 30 = 930)
      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseUnits("930", 18));
    });

    it("T21: user summary tracking", async function () {
      await staking.connect(oracle).recordStake(alice.address, 1, 0, ethers.parseUnits("50", 18));
      await staking.connect(oracle).recordStake(alice.address, 2, 0, ethers.parseUnits("30", 18));

      const [staked, returned, burned, count] = await staking.getUserSummary(alice.address);
      expect(staked).to.equal(ethers.parseUnits("80", 18));
      expect(count).to.equal(2);

      // Settle first stake as win
      await staking.connect(oracle).settleWin(1, 0);
      const [staked2, returned2] = await staking.getUserSummary(alice.address);
      expect(staked2).to.equal(ethers.parseUnits("30", 18));
      expect(returned2).to.equal(ethers.parseUnits("50", 18));
    });

    it("T22: idea stake tracking", async function () {
      await staking.connect(oracle).recordStake(alice.address, 42, 0, ethers.parseUnits("50", 18));
      await staking.connect(oracle).recordStake(bob.address, 42, 1, ethers.parseUnits("20", 18));

      const ideaIds = await staking.getIdeaStakeIds(42);
      expect(ideaIds.length).to.equal(2);
      expect(await staking.ideaTotalStaked(42)).to.equal(ethers.parseUnits("70", 18));
    });

    it("T23: sweep slashed tokens to treasury", async function () {
      await staking.connect(oracle).recordStake(alice.address, 1, 0, ethers.parseUnits("100", 18));
      await staking.connect(oracle).settleLoss(1, ethers.parseUnits("70", 18), 0);

      // 70 UPC still in staking contract
      expect(await token.balanceOf(await staking.getAddress())).to.equal(ethers.parseUnits("70", 18));

      // Sweep to treasury
      await staking.sweepToTreasury(await treasury.getAddress());
      expect(await token.balanceOf(await staking.getAddress())).to.equal(0);
      expect(await token.balanceOf(await treasury.getAddress())).to.equal(ethers.parseUnits("70", 18));
    });

    it("T24: non-oracle cannot record or settle", async function () {
      await expect(
        staking.connect(alice).recordStake(alice.address, 1, 0, ONE_UPC)
      ).to.be.revertedWith("Not oracle");
      await expect(
        staking.connect(alice).settleWin(1, 0)
      ).to.be.revertedWith("Not oracle");
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // Treasury
  // ════════════════════════════════════════════════════════════════════════

  describe("Treasury", function () {
    it("T25: 2-of-3 multisig withdrawal", async function () {
      // Fund treasury
      await admin.sendTransaction({
        to: await treasury.getAddress(),
        value: ethers.parseEther("10"),
      });

      // Create proposal (admin is signer 1)
      await treasury.createProposal(carol.address, ethers.parseEther("1"), "Test payout");

      // Alice approves (signer 2) → 2-of-3 met → auto-executes
      const balBefore = await ethers.provider.getBalance(carol.address);
      await treasury.connect(alice).approveProposal(1);
      const balAfter = await ethers.provider.getBalance(carol.address);

      expect(balAfter - balBefore).to.equal(ethers.parseEther("1"));
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // Governance
  // ════════════════════════════════════════════════════════════════════════

  describe("Governance", function () {
    it("T26: contract registry", async function () {
      const [t, i, b, tr, s] = await governance.getContractAddresses();
      expect(t).to.equal(await token.getAddress());
      expect(i).to.equal(await issuance.getAddress());
      expect(b).to.equal(await burn.getAddress());
      expect(tr).to.equal(await treasury.getAddress());
      expect(s).to.equal(await staking.getAddress());
    });

    it("T27: emergency pause/unpause across all contracts", async function () {
      await governance.emergencyPause();
      expect(await token.paused()).to.be.true;
      expect(await issuance.paused()).to.be.true;
      expect(await burn.paused()).to.be.true;
      expect(await staking.paused()).to.be.true;

      await governance.emergencyUnpause();
      expect(await token.paused()).to.be.false;
    });

    it("T28: oracle propagated to issuance and staking", async function () {
      await governance.setOracle(carol.address);
      expect(await issuance.oracle()).to.equal(carol.address);
      expect(await staking.oracle()).to.equal(carol.address);
    });

    it("T29: parameter changes are recorded", async function () {
      await governance.setBaseAllocation(ethers.parseUnits("1000", 18));
      const change = await governance.getParameterChange(0);
      expect(change.paramName).to.equal("baseAllocation");
    });
  });
});
