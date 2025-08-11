## CCIP DeFi Lending Protocol

**Overview:**

- User deposits WETH to the Collateral Manager contract on the local chain, such as on the Ethereum Mainnet. The user then requests tokens from the Lending Manager on the destination chain, such as on Arbitrum, which then mints the user stablecoins from the Stablecoin contract. The quantity of stablecoins minted depends on ETH's current price. For example, if ETH is $2000, and a user deposits 1 ETH, they will receive 2000 stablecoins.

- The owner of the contracr must, however, allow each chain and sender. For example, if the contract only permits cross-chain messaging between Ethereum Mainnet and Arbitrum, and a user attempts to bridge messaging to Avalanche, it will revert.

**Notes on testing:**

- To test Chainlink CCIP, I used Chainlink-Local. I created two forks: Ethereum Sepolia (where the Collateral Manager was deployed) and Arbitrum Sepolia (where the Lending Manager and Stablecoin was deployed).

**100% coverage on each contract:**
╭------------------------------------------------+------------------+------------------+-----------------+-----------------╮
| File | % Lines | % Statements | % Branches | % Funcs |
+==========================================================================================================================+
|------------------------------------------------+------------------+------------------+-----------------+-----------------|
| src/CollateralManager.sol | 100.00% (89/89) | 100.00% (87/87) | 100.00% (10/10) | 100.00% (21/21) |
|------------------------------------------------+------------------+------------------+-----------------+-----------------|
| src/LendingManager.sol | 100.00% (68/68) | 100.00% (54/54) | 100.00% (7/7) | 100.00% (20/20) |
|------------------------------------------------+------------------+------------------+-----------------+-----------------|
| src/Stablecoin.sol | 100.00% (6/6) | 100.00% (3/3) | 100.00% (0/0) | 100.00% (3/3) |
╰------------------------------------------------+------------------+------------------+-----------------+-----------------╯
