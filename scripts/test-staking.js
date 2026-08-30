const { ethers } = require("hardhat");

async function main() {
  const TOKEN = "0x07EBC3844482E9dAd93F8D20c6e50f0F92a7ec60";
  const STAKING = "0x94e136E6a9cBa5e6A218D83544471787069434B0";
  const USER = "0x1Bdb337a85036d3BbE08862Ff012Dd076CdC4C20";

  const [deployer] = await ethers.getSigners();
  console.log("Oracle/Deployer:", deployer.address);

  const token = await ethers.getContractAt("UpsideToken", TOKEN);
  const staking = await ethers.getContractAt("IdeaStaking", STAKING);

  // Step 1: Check balance
  const bal = await token.balanceOf(USER);
  console.log("UPC balance:", ethers.formatEther(bal));

  // Step 2: Approve IdeaStaking to spend 50 UPC on behalf of user
  // Since deployer = user in this case, we can approve directly
  const approveAmt = ethers.parseEther("50");
  console.log("\nApproving 50 UPC for IdeaStaking...");
  const approveTx = await token.approve(STAKING, approveAmt);
  await approveTx.wait();
  console.log("Approved. Tx:", approveTx.hash);

  // Step 3: Check allowance
  const allowance = await token.allowance(USER, STAKING);
  console.log("Allowance:", ethers.formatEther(allowance));

  // Step 4: Oracle records a stake (ideaId=1, type=0 self-stake, 10 UPC)
  const stakeAmt = ethers.parseEther("10");
  console.log("\nRecording stake: 10 UPC, ideaId=1, self-stake...");
  const stakeTx = await staking.recordStake(USER, 1, 0, stakeAmt);
  await stakeTx.wait();
  console.log("Staked! Tx:", stakeTx.hash);

  // Step 5: Check results
  const balAfter = await token.balanceOf(USER);
  const stakingBal = await token.balanceOf(STAKING);
  const summary = await staking.getUserSummary(USER);

  console.log("\n--- Results ---");
  console.log("User balance after:", ethers.formatEther(balAfter), "UPC");
  console.log("Staking contract holds:", ethers.formatEther(stakingBal), "UPC");
  console.log("User total staked:", ethers.formatEther(summary[0]));
  console.log("User total returned:", ethers.formatEther(summary[1]));
  console.log("User stake count:", summary[2].toString());
}

main().catch(console.error);
