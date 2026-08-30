const { ethers } = require("hardhat");

async function main() {
  const TOKEN_ADDRESS = "0x07EBC3844482E9dAd93F8D20c6e50f0F92a7ec60";
  const RECIPIENT = "0x1Bdb337a85036d3BbE08862Ff012Dd076CdC4C20";
  const AMOUNT = ethers.parseEther("1000"); // 1000 UPC

  const [deployer] = await ethers.getSigners();
  console.log("Minting with:", deployer.address);

  const token = await ethers.getContractAt("UpsideToken", TOKEN_ADDRESS);
  
 const tx = await token.mintReserve(RECIPIENT, AMOUNT);
  console.log("Tx hash:", tx.hash);
  await tx.wait();
  
  const balance = await token.balanceOf(RECIPIENT);
  console.log("New balance:", ethers.formatEther(balance), "UPC");
}

main().catch(console.error);
