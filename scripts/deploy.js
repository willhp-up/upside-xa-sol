const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("=== UPSIDE XA v2.0 — FULL DEPLOYMENT ===\n");
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // ── 1. UpsideToken ─────────────────────────────────────────────────────
  console.log("\n1. Deploying UpsideToken...");
  const Token = await hre.ethers.getContractFactory("UpsideToken");
  const token = await Token.deploy();  // constructor() — no args
  await token.waitForDeployment();
  const tokenAddr = await token.getAddress();
  console.log("   UpsideToken:", tokenAddr);

  // ── 2. RewardIssuance ──────────────────────────────────────────────────
  console.log("2. Deploying RewardIssuance...");
  const Issuance = await hre.ethers.getContractFactory("RewardIssuance");
  const issuance = await Issuance.deploy();  // constructor() — no args
  await issuance.waitForDeployment();
  const issuanceAddr = await issuance.getAddress();
  console.log("   RewardIssuance:", issuanceAddr);

  // ── 3. BurnMechanism ──────────────────────────────────────────────────
  console.log("3. Deploying BurnMechanism...");
  const Burn = await hre.ethers.getContractFactory("BurnMechanism");
  const burn = await Burn.deploy();  // constructor() — no args
  await burn.waitForDeployment();
  const burnAddr = await burn.getAddress();
  console.log("   BurnMechanism:", burnAddr);

  // ── 4. IdeaStaking ────────────────────────────────────────────────────
  console.log("4. Deploying IdeaStaking...");
  const Staking = await hre.ethers.getContractFactory("IdeaStaking");
  const staking = await Staking.deploy();  // constructor() — no args
  await staking.waitForDeployment();
  const stakingAddr = await staking.getAddress();
  console.log("   IdeaStaking:", stakingAddr);

  // ── 5. Treasury ───────────────────────────────────────────────────────
  // 2-of-3 multisig. For testnet, use deployer as all 3 signers.
  // Replace with real signers for production.
  console.log("5. Deploying Treasury...");
  const signer2 = "0x0000000000000000000000000000000000000002";
  const signer3 = "0x0000000000000000000000000000000000000003";
  const Treasury = await hre.ethers.getContractFactory("Treasury");
  const treasury = await Treasury.deploy(deployer.address, signer2, signer3);
  await treasury.waitForDeployment();
  const treasuryAddr = await treasury.getAddress();
  console.log("   Treasury:", treasuryAddr);

  // ── 6. Governance ─────────────────────────────────────────────────────
  console.log("6. Deploying Governance...");
  const Governance = await hre.ethers.getContractFactory("Governance");
  const governance = await Governance.deploy();  // constructor() — no args
  await governance.waitForDeployment();
  const governanceAddr = await governance.getAddress();
  console.log("   Governance:", governanceAddr);

  // ── 7. Wire contracts together ────────────────────────────────────────
  console.log("\n7. Wiring contracts...");

  // Token → knows about issuance and burn contracts
  let tx = await token.setIssuanceContract(issuanceAddr);
  await tx.wait();
  console.log("   Token → Issuance linked");

  tx = await token.setBurnContract(burnAddr);
  await tx.wait();
  console.log("   Token → Burn linked");

  tx = await token.setGovernanceContract(governanceAddr);
  await tx.wait();
  console.log("   Token → Governance linked");

  // Issuance → knows about token and governance
  tx = await issuance.setTokenContract(tokenAddr);
  await tx.wait();
  console.log("   Issuance → Token linked");

  tx = await issuance.setGovernanceContract(governanceAddr);
  await tx.wait();
  console.log("   Issuance → Governance linked");

  // Burn → knows about token and governance
  tx = await burn.setTokenContract(tokenAddr);
  await tx.wait();
  console.log("   Burn → Token linked");

  tx = await burn.setGovernanceContract(governanceAddr);
  await tx.wait();
  console.log("   Burn → Governance linked");

  // IdeaStaking → knows about token and governance
  tx = await staking.setTokenContract(tokenAddr);
  await tx.wait();
  console.log("   IdeaStaking → Token linked");

  tx = await staking.setGovernanceContract(governanceAddr);
  await tx.wait();
  console.log("   IdeaStaking → Governance linked");

  // Treasury → governance
  tx = await treasury.setGovernanceContract(governanceAddr);
  await tx.wait();
  console.log("   Treasury → Governance linked");

  // Governance → register all contracts
  tx = await governance.registerContracts(tokenAddr, issuanceAddr, burnAddr, treasuryAddr, stakingAddr);
  await tx.wait();
  console.log("   Governance → All contracts registered");

  // Set oracle (deployer for testnet)
  tx = await governance.setOracle(deployer.address);
  await tx.wait();
  console.log("   Oracle set to deployer");

  // ── 8. Verification ───────────────────────────────────────────────────
  console.log("\n8. Verifying wiring...");

  const addrs = await governance.getContractAddresses();
  console.log("   Governance sees Token:", addrs[0] === tokenAddr ? "✓" : "✗");
  console.log("   Governance sees Issuance:", addrs[1] === issuanceAddr ? "✓" : "✗");
  console.log("   Governance sees Burn:", addrs[2] === burnAddr ? "✓" : "✗");
  console.log("   Governance sees Treasury:", addrs[3] === treasuryAddr ? "✓" : "✗");
  console.log("   Governance sees IdeaStaking:", addrs[4] === stakingAddr ? "✓" : "✗");

  const tokenIssuance = await token.issuanceContract();
  const tokenBurn = await token.burnContract();
  console.log("   Token sees Issuance:", tokenIssuance === issuanceAddr ? "✓" : "✗");
  console.log("   Token sees Burn:", tokenBurn === burnAddr ? "✓" : "✗");

  // ── Done ──────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════════");
  console.log("  DEPLOYMENT COMPLETE — Upside Xa v2.0");
  console.log("═══════════════════════════════════════════════════════════");
  console.log("  UpsideToken:     ", tokenAddr);
  console.log("  RewardIssuance:  ", issuanceAddr);
  console.log("  BurnMechanism:   ", burnAddr);
  console.log("  IdeaStaking:     ", stakingAddr);
  console.log("  Treasury:        ", treasuryAddr);
  console.log("  Governance:      ", governanceAddr);
  console.log("  Oracle:          ", deployer.address);
  console.log("═══════════════════════════════════════════════════════════\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
