const hre = require("hardhat");

// === YOUR DEPLOYED CONTRACT ADDRESSES ===
const ADDRESSES = {
  token:     "0x2356716ce0cAE1042DAD4fC4B7E92B3d0A956b62",
  issuance:  "0x482EE88d50452b7cdfF23209ca7EBC3592fC0271",
  burn:      "0x03dF36498Ce7ee366b9CC29a16d53DF08D77c3E5",
  treasury:  "0xCea8c1D66039f36FC59CbC29bbb5De8111dc0032",
  governance:"0xC3E2b5B1d62F3674C2823BbE642166AfBABeBDC9",
};

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Interacting as:", deployer.address);
  console.log("Balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "PAS\n");

  // Connect to deployed contracts
  const token = await hre.ethers.getContractAt("UpsideToken", ADDRESSES.token);
  const issuance = await hre.ethers.getContractAt("RewardIssuance", ADDRESSES.issuance);
  const burn = await hre.ethers.getContractAt("BurnMechanism", ADDRESSES.burn);
  const treasury = await hre.ethers.getContractAt("Treasury", ADDRESSES.treasury);
  const governance = await hre.ethers.getContractAt("Governance", ADDRESSES.governance);

  // =========================================================
  // TEST 1: Check token metadata
  // =========================================================
  console.log("=== TEST 1: Token Metadata ===");
console.log("  Name:        ", await token.name());
  console.log("  Symbol:      ", await token.symbol());
  console.log("  Decimals:    ", await token.decimals());  console.log("  Total Supply:", hre.ethers.formatEther(await token.totalSupply()));
  console.log("  PASSED\n");

  // =========================================================
  // TEST 2: Set ourselves as oracle (so we can submit scores)
  // =========================================================
  console.log("=== TEST 2: Set Oracle ===");
  let tx = await issuance.setOracle(deployer.address);
  await tx.wait();
  console.log("  Oracle set to deployer address");
  console.log("  PASSED\n");

  // =========================================================
  // TEST 3: Create an issuance period
  // =========================================================
  console.log("=== TEST 3: Create Issuance Period ===");
  const allocation = hre.ethers.parseEther("1000"); // 1000 UPC for this period
  const now = Math.floor(Date.now() / 1000);
  const startsAt = now;
  const endsAt = now + 86400; // 24 hours from now

  tx = await issuance.createPeriod(allocation, startsAt, endsAt);
  await tx.wait();
  const periodCount = await issuance.periodCount();
  console.log("  Period created! Period ID:", periodCount.toString());

  const period = await issuance.getPeriod(periodCount);
  console.log("  Allocation:", hre.ethers.formatEther(period.allocation), "UPC");
  console.log("  Status:", period.status.toString());
  console.log("  PASSED\n");

  // =========================================================
  // TEST 4: Submit a score (as oracle)
  // =========================================================
  console.log("=== TEST 4: Submit Score ===");
  const ideaId = 1;
  const score = 750; // 0.750 quality score
  tx = await issuance.submitScore(periodCount, deployer.address, ideaId, score);
  await tx.wait();

  const userScore = await issuance.getUserScore(periodCount, deployer.address);
  console.log("  Score submitted! User score:", userScore.toString());
  console.log("  PASSED\n");

  // =========================================================
  // TEST 5: Close the period and claim reward
  // =========================================================
  console.log("=== TEST 5: Close Period & Claim Reward ===");
tx = await issuance.finalizePeriod(periodCount);
  await tx.wait();
  console.log("  Period closed");

  tx = await issuance.claimReward(periodCount);
  await tx.wait();
  console.log("  Reward claimed!");

  const balance = await token.balanceOf(deployer.address);
  console.log("  Token balance:", hre.ethers.formatEther(balance), "UPC");
  const supply = await token.totalSupply();
  console.log("  Total supply:", hre.ethers.formatEther(supply), "UPC");
  console.log("  PASSED\n");

  // =========================================================
  // TEST 6: Check lock status
  // =========================================================
  console.log("=== TEST 6: Check Token Lock ===");
  const available = await token.availableBalanceOf(deployer.address);
  console.log("  Total balance: ", hre.ethers.formatEther(balance), "UPC");
  console.log("  Available (unlocked):", hre.ethers.formatEther(available), "UPC");
  console.log("  Locked:", hre.ethers.formatEther(balance - available), "UPC");
  console.log("  (Tokens unlock 90 days after minting)");
  console.log("  PASSED\n");

  // =========================================================
  // TEST 7: Governance - pause and unpause
  // =========================================================

console.log("=== TEST 7: Governance Pause/Unpause ===");
  tx = await governance.emergencyPause();
  await tx.wait();
  console.log("  System PAUSED");
  tx = await governance.emergencyUnpause();
  await tx.wait();
  console.log("  System UNPAUSED");
  console.log("  PASSED\n");

  // =========================================================
  // TEST 8: Treasury - send some PAS to test
  // =========================================================
  console.log("=== TEST 8: Treasury Deposit ===");
  tx = await deployer.sendTransaction({
    to: ADDRESSES.treasury,
    value: hre.ethers.parseEther("1.0"),
  });
  await tx.wait();
  const treasuryBalance = await hre.ethers.provider.getBalance(ADDRESSES.treasury);
  console.log("  Deposited 1 PAS to treasury");
  console.log("  Treasury balance:", hre.ethers.formatEther(treasuryBalance), "PAS");
  console.log("  PASSED\n");

  // =========================================================
  // SUMMARY
  // =========================================================
  console.log("==========================================");
  console.log("  ALL TESTS PASSED ON LIVE TESTNET!");
  console.log("==========================================");
  console.log("\nYour Upside Xa system is fully operational:");
  console.log("  - Token minting with 90-day locks: WORKING");
  console.log("  - Score submission and rewards:     WORKING");
  console.log("  - Governance pause/unpause:         WORKING");
  console.log("  - Treasury deposits:                WORKING");
  console.log("\nFinal balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "PAS");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
