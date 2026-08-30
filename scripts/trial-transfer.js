const hre = require("hardhat");
async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const TOKEN_ADDRESS = "0xa7e625C033d468E22825b15b10570eFd188Fba5A";
  const token = await hre.ethers.getContractAt("UpsideToken", TOKEN_ADDRESS);
  const mintAmount = hre.ethers.parseUnits("10000", 18);
  console.log("Minting 10000 UPC...");
  const mintTx = await token.mintReserve(deployer.address, mintAmount);
  await mintTx.wait();
  console.log("Mint tx:", mintTx.hash);
  console.log("Your balance:", hre.ethers.formatUnits(await token.balanceOf(deployer.address), 18), "UPC");
  const RECIPIENT = "0x5F6Af95fF8a973bD0f8415e26429e129bFe6aBda";
  const sendAmount = hre.ethers.parseUnits("1000", 18);
  console.log("Transferring 1000 UPC to", RECIPIENT);
  const transferTx = await token.transfer(RECIPIENT, sendAmount);
  await transferTx.wait();
  console.log("Transfer tx:", transferTx.hash);
  console.log("Your balance:", hre.ethers.formatUnits(await token.balanceOf(deployer.address), 18), "UPC");
  console.log("Recipient balance:", hre.ethers.formatUnits(await token.balanceOf(RECIPIENT), 18), "UPC");
}
main().catch(console.error);
