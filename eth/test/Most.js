const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { execSync: exec } = require("child_process");

// Import utils
const { addressToBytes32, getRandomAlephAccount } = require("./TestUtils");

const TOKEN_AMOUNT = 1000;
const ALEPH_ACCOUNT = getRandomAlephAccount(3);
const WRAPPED_TOKEN_ADDRESS = getRandomAlephAccount(5);

describe("Most", function () {
  describe("Constructor", function () {
    it("Reverts if threshold is 0", async () => {
      const signers = await ethers.getSigners();
      const accounts = signers.map((s) => s.address);

      const Most = await ethers.getContractFactory("Most");
      await expect(
        upgrades.deployProxy(Most, [[accounts[0]], 0, accounts[0]], {
          initializer: "initialize",
          kind: "uups",
        }),
      ).to.be.revertedWith("Signature threshold must be greater than 0");
    });
    it("Reverts if threshold is greater than number of guardians", async () => {
      const signers = await ethers.getSigners();
      const accounts = signers.map((s) => s.address);

      const Most = await ethers.getContractFactory("Most");
      await expect(
        upgrades.deployProxy(Most, [[accounts[0]], 2, accounts[0]], {
          initializer: "initialize",
          kind: "uups",
        }),
      ).to.be.revertedWith("Not enough guardians specified");
    });
  });

  async function deployEightGuardianMostFixture() {
    const signers = await ethers.getSigners();
    const accounts = signers.map((s) => s.address);

    const Most = await ethers.getContractFactory("Most");
    const most = await upgrades.deployProxy(
      Most,
      [accounts.slice(1, 9), 5, accounts[0]],
      {
        initializer: "initialize",
        kind: "uups",
      },
    );
    const mostAddress = await most.getAddress();

    const Token = await ethers.getContractFactory("Token");
    const token = await Token.deploy(
      "10000000000000000000000000",
      "TestToken",
      "TEST",
    );
    const tokenAddressBytes32 = addressToBytes32(await token.getAddress());

    return {
      most,
      token,
      tokenAddressBytes32,
      mostAddress,
    };
  }

  describe("sendRequest", function () {
    it("Reverts if token is not whitelisted", async () => {
      const { most, token, tokenAddressBytes32, mostAddress } =
        await loadFixture(deployEightGuardianMostFixture);

      await token.approve(mostAddress, TOKEN_AMOUNT);
      await expect(
        most.sendRequest(tokenAddressBytes32, TOKEN_AMOUNT, ALEPH_ACCOUNT),
      ).to.be.revertedWith("Unsupported pair");
    });

    it("Reverts if token transfer is not approved", async () => {
      const { most, tokenAddressBytes32 } = await loadFixture(
        deployEightGuardianMostFixture,
      );

      await most.addPair(tokenAddressBytes32, WRAPPED_TOKEN_ADDRESS);
      await expect(
        most.sendRequest(tokenAddressBytes32, TOKEN_AMOUNT, ALEPH_ACCOUNT),
      ).to.be.reverted;
    });

    it("Transfers tokens to Most", async () => {
      const { most, token, tokenAddressBytes32, mostAddress } =
        await loadFixture(deployEightGuardianMostFixture);

      await token.approve(mostAddress, TOKEN_AMOUNT);
      await most.addPair(tokenAddressBytes32, WRAPPED_TOKEN_ADDRESS);
      await most.sendRequest(tokenAddressBytes32, TOKEN_AMOUNT, ALEPH_ACCOUNT);

      expect(await token.balanceOf(mostAddress)).to.equal(TOKEN_AMOUNT);
    });

    it("Emits correct event", async () => {
      const { most, token, tokenAddressBytes32, mostAddress } =
        await loadFixture(deployEightGuardianMostFixture);

      await token.approve(mostAddress, TOKEN_AMOUNT);
      await most.addPair(tokenAddressBytes32, WRAPPED_TOKEN_ADDRESS);
      await expect(
        most.sendRequest(tokenAddressBytes32, TOKEN_AMOUNT, ALEPH_ACCOUNT),
      )
        .to.emit(most, "CrosschainTransferRequest")
        .withArgs(0, WRAPPED_TOKEN_ADDRESS, TOKEN_AMOUNT, ALEPH_ACCOUNT, 0);
    });
  });

  describe("receiveRequest", function () {
    it("Reverts if caller is not a guardian", async () => {
      const { most, tokenAddressBytes32 } = await loadFixture(
        deployEightGuardianMostFixture,
      );
      const accounts = await ethers.getSigners();
      const ethAddress = addressToBytes32(accounts[10].address);
      const requestHash = ethers.solidityPackedKeccak256(
        ["uint256", "bytes32", "uint256", "bytes32", "uint256"],
        [0, tokenAddressBytes32, TOKEN_AMOUNT, ethAddress, 0],
      );

      await expect(
        most
          .connect(accounts[0])
          .receiveRequest(
            requestHash,
            0,
            tokenAddressBytes32,
            TOKEN_AMOUNT,
            ethAddress,
            0,
          ),
      ).to.be.revertedWith("Not a member of the guardian committee");
    });

    it("Reverts if request has already been signed by a guardian", async () => {
      const { most, tokenAddressBytes32 } = await loadFixture(
        deployEightGuardianMostFixture,
      );
      const accounts = await ethers.getSigners();
      const ethAddress = addressToBytes32(accounts[10].address);
      const requestHash = ethers.solidityPackedKeccak256(
        ["uint256", "bytes32", "uint256", "bytes32", "uint256"],
        [0, tokenAddressBytes32, TOKEN_AMOUNT, ethAddress, 0],
      );

      await most
        .connect(accounts[1])
        .receiveRequest(
          requestHash,
          0,
          tokenAddressBytes32,
          TOKEN_AMOUNT,
          ethAddress,
          0,
        );
      await expect(
        most
          .connect(accounts[1])
          .receiveRequest(
            requestHash,
            0,
            tokenAddressBytes32,
            TOKEN_AMOUNT,
            ethAddress,
            0,
          ),
      ).to.be.revertedWith("This guardian has already signed this request");
    });

    it("Ignores already executed requests", async () => {
      const { most, token, tokenAddressBytes32 } = await loadFixture(
        deployEightGuardianMostFixture,
      );
      const accounts = await ethers.getSigners();
      const ethAddress = addressToBytes32(accounts[10].address);
      const requestHash = ethers.solidityPackedKeccak256(
        ["uint256", "bytes32", "uint256", "bytes32", "uint256"],
        [0, tokenAddressBytes32, TOKEN_AMOUNT, ethAddress, 0],
      );

      // Provide funds for Most
      await token.transfer(await most.getAddress(), TOKEN_AMOUNT * 2);

      for (let i = 1; i < 6; i++) {
        await most
          .connect(accounts[i])
          .receiveRequest(
            requestHash,
            0,
            tokenAddressBytes32,
            TOKEN_AMOUNT,
            ethAddress,
            0,
          );
      }

      await expect(
        most
          .connect(accounts[6])
          .receiveRequest(
            requestHash,
            0,
            tokenAddressBytes32,
            TOKEN_AMOUNT,
            ethAddress,
            0,
          ),
      )
        .to.emit(most, "ProcessedRequestSigned")
        .withArgs(requestHash, accounts[6].address);
    });

    it("Unlocks tokens for the user", async () => {
      const { most, token, tokenAddressBytes32 } = await loadFixture(
        deployEightGuardianMostFixture,
      );
      const accounts = await ethers.getSigners();
      const ethAddress = addressToBytes32(accounts[10].address);
      const requestHash = ethers.solidityPackedKeccak256(
        ["uint256", "bytes32", "uint256", "bytes32", "uint256"],
        [0, tokenAddressBytes32, TOKEN_AMOUNT, ethAddress, 0],
      );

      // Provide funds for Most
      await token.transfer(await most.getAddress(), TOKEN_AMOUNT * 2);

      for (let i = 1; i < 6; i++) {
        await most
          .connect(accounts[i])
          .receiveRequest(
            requestHash,
            0,
            tokenAddressBytes32,
            TOKEN_AMOUNT,
            ethAddress,
            0,
          );
      }

      expect(await token.balanceOf(accounts[10].address)).to.equal(
        TOKEN_AMOUNT,
      );
    });

    it("Reverts on non-matching hash", async () => {
      const { most, token, tokenAddressBytes32 } = await loadFixture(
        deployEightGuardianMostFixture,
      );
      const accounts = await ethers.getSigners();
      const ethAddress = addressToBytes32(accounts[10].address);
      const requestHash = ethers.solidityPackedKeccak256(
        ["uint256", "bytes32", "uint256", "bytes32", "uint256"],
        [0, tokenAddressBytes32, TOKEN_AMOUNT, ethAddress, 1],
      );

      // Provide funds for Most
      await token.transfer(await most.getAddress(), TOKEN_AMOUNT * 2);

      await expect(
        most
          .connect(accounts[1])
          .receiveRequest(
            requestHash,
            0,
            tokenAddressBytes32,
            TOKEN_AMOUNT,
            ethAddress,
            0,
          ),
      ).to.be.revertedWith("Hash does not match the data");
    });

    it("Committee rotation", async () => {
      const { most, token, tokenAddressBytes32 } = await loadFixture(
        deployEightGuardianMostFixture,
      );
      const accounts = await ethers.getSigners();
      const ethAddress = addressToBytes32(accounts[10].address);
      const requestHashOld = ethers.solidityPackedKeccak256(
        ["uint256", "bytes32", "uint256", "bytes32", "uint256"],
        [0, tokenAddressBytes32, TOKEN_AMOUNT, ethAddress, 0],
      );
      const requestHashNew = ethers.solidityPackedKeccak256(
        ["uint256", "bytes32", "uint256", "bytes32", "uint256"],
        [1, tokenAddressBytes32, TOKEN_AMOUNT, ethAddress, 0],
      );

      // Provide funds for Most
      await token.transfer(await most.getAddress(), TOKEN_AMOUNT * 2);

      // Rotate committee
      await most.connect(accounts[0]).setCommittee(accounts.slice(3, 10), 5);

      await most
        .connect(accounts[2])
        .receiveRequest(
          requestHashOld,
          0,
          tokenAddressBytes32,
          TOKEN_AMOUNT,
          ethAddress,
          0,
        );

      await most
        .connect(accounts[9])
        .receiveRequest(
          requestHashNew,
          1,
          tokenAddressBytes32,
          TOKEN_AMOUNT,
          ethAddress,
          0,
        );

      await expect(
        most
          .connect(accounts[2])
          .receiveRequest(
            requestHashNew,
            1,
            tokenAddressBytes32,
            TOKEN_AMOUNT,
            ethAddress,
            0,
          ),
      ).to.be.revertedWith("Not a member of the guardian committee");

      await expect(
        most
          .connect(accounts[9])
          .receiveRequest(
            requestHashOld,
            0,
            tokenAddressBytes32,
            TOKEN_AMOUNT,
            ethAddress,
            0,
          ),
      ).to.be.revertedWith("Not a member of the guardian committee");
    });
  });

  describe("Upgrade", function () {
    it("Most contract can be upgraded", async () => {
      exec("cp ./contracts/Most.sol ./contracts/MostV2.sol", (error) => {
        if (error !== null) {
          console.log("exec error: " + error);
        }
        exec(
          'sed -i "17 a     uint256 public test;" ./contracts/MostV2.sol',
          async (error, stdout, stderr) => {
            if (error !== null) {
              console.log("exec error: " + error);
            }

            const { most, mostAddress } = await loadFixture(
              deployEightGuardianMostFixture,
            );

            const accounts = await ethers.getSigners();
            let committee = accounts.slice(2, 9).map((x) => x.address);
            let threshold = 4;
            await most.setCommittee(committee, threshold);

            const MostV2 = await ethers.getContractFactory("MostV2");
            const mostV2 = await upgrades.upgradeProxy(mostAddress, MostV2);

            const address = await mostV2.getAddress();
            // address is preserved
            expect(address).to.be.equal(mostAddress);

            // state is preserved
            expect(most.isInCommittee(committee[0]));

            // no state overwrite
            expect(most.test()).to.be.equal(0);
          },
        );
      });

      // clean up
      exec("rm ./contracts/MostV2.sol", (error, stdout, stderr) => {
        if (error !== null) {
          console.log("exec error: " + error);
        }
      });
    });
  });
});
