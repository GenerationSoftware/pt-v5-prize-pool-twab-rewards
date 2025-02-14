# PoolTogether V5 Prize Pool Twab Rewards

[![Code Coverage](https://github.com/generationsoftware/pt-v5-prize-pool-twab-rewards/actions/workflows/coverage.yml/badge.svg)](https://github.com/generationsoftware/pt-v5-prize-pool-twab-rewards/actions/workflows/coverage.yml)
[![built-with openzeppelin](https://img.shields.io/badge/built%20with-OpenZeppelin-3677FF)](https://docs.openzeppelin.com/)
![MIT license](https://img.shields.io/badge/license-MIT-blue)

The Prize Pool Twab Rewards contract allows anyone to distribute tokens to all contributors to a [PoolTogether](https://pooltogether.com/) Prize Pool.

## Testnet Deployment

[Optimism Sepolia](https://sepolia-optimism.etherscan.io/address/0x1B7070eb6f871ba0d77470918502F8D788978FA3)

[Tx of Promotion 1](https://sepolia-optimism.etherscan.io/tx/0xed98c647d8f40fb8647b42fed0380a8d66dcdd67b9a3631a6e8f2cfc636752f7)

## How it Works

Typically Prize Pool "contributors" are vaults that hold user deposits and contribute the yield to the Prize Pool. The Prize Pool Twab Rewards contract distributes incentives to those users.

The contract divides time into "epochs" over which contributions are measured. To compute a user's rewards for a given epoch:

```
usersVaultBalance = the average balance they held during the epoch (pulled from the TwabController)
vaultTotalSupply = the average total supply for a vault during the epoch (pulled from the TwabController)

vaultContributions = the vault's contributions to the prize pool during the epoch (pulled from the PrizePool)
totalContributions = the total contributions to the prize pool during the epoch (pulled from the PrizePool)

userRewards = (usersVaultBalance / vaultTotalSupply) * (vaultContributions / totalContributions) * tokensPerEpoch
```

So each user's portion of the rewards is equivalent to their portion of the vault * the vaults portion of contributions to the prize pool.

- [TwabController on Github](https://github.com/GenerationSoftware/pt-v5-twab-controller)
- [Prize Pool on Github](https://github.com/GenerationSoftware/pt-v5-prize-pool)

## Usage

### Creating the Promotion

The contract supports any number of incentive "promotions". You can create a promotion by calling:

```
function createPromotion(
    IERC20 token,
    uint40 startTimestamp,
    uint104 tokensPerEpoch,
    uint40 epochDuration,
    uint8 numberOfEpochs
) external returns (uint256);
```

| Parameter | Description |
| ---- | ----- |
| token | The token to distribute. |
| startTimestamp | The timestamp at which the promotion begins. The value MUST align with a draw start or end in the Prize Pool. |
| tokensPerEpoch | The number of tokens to distribute for an epoch. An epoch is the duration of time over which contributions are measured and incentives doled out proportionally |
| epochDuration | The length of time of the epoch in seconds. The value MUST be a multiple of the draw period in the Prize Pool. |
| numberOfEpochs | The number of epochs that the promotion will run for. |

Calling `createPromotion` will transfer the tokens from the caller to the contract. The caller must have already approved the token spend. The amount of spend is `tokensPerEpoch * numberOfEpochs`.

The function returns the promotion id.

**Example**

Let's say I want to distribute 1000 WETH per week for 10 weeks. Assuming the start time and duration are draw-aligned, I would call `createPromotion` with:

```
uint256 promotionId = createPromotion(
    wethAddress,
    86400,
    1000e18,
    86400,
    10
);
```

### Claiming Rewards

Anyone may claim rewards for a user by calling `claimRewards`:

```
function claimRewards(address vault, address user, uint256 promotionId, uint8[] calldata epochIds) external returns (uint256);
```

| Param | Description |
| --- | --- |
| vault | The contributor to the prize pool (usually a vault) |
| user | The user whose balance should be looked up in the TwabController |
| promotionId | The id of the promotion to claim for |
| epochsIds | An array of the epochs to claim |

The function returns the total rewards claimed.

**Example**

Let's say a user of a vault wishes to claim the rewards for the above create promotion example.  Assuming they deposited into the vault halfway through the promotion, they would call `claimRewards` like so:

```
uint totalRewards = claimRewards(vaultAddress, userAddress, promotionId, [5, 6, 7, 8, 9]);
```

Note that this is pseudocode: arrays cannot be defined inline in Solidity!


## Development

### Installation

You may have to install the following tools to use this repository:

- [Foundry](https://github.com/foundry-rs/foundry) to compile and test contracts
- [direnv](https://direnv.net/) to handle environment variables
- [lcov](https://github.com/linux-test-project/lcov) to generate the code coverage report

Install dependencies:

```
npm i
```

### Env

Copy `.env.example` and write down the env variables needed to run this project.

```
cp .env.example .env
```

Once your env variables are setup, load them with:

```
direnv allow
```

### Compile

Run the following command to compile the contracts:

```
npm run compile
```

### Coverage

Forge is used for coverage, run it with:

```
npm run coverage
```

You can then consult the report by opening `coverage/index.html`:

```
open coverage/index.html
```

### Code quality

[Husky](https://typicode.github.io/husky/#/) is used to run [lint-staged](https://github.com/okonet/lint-staged) and tests when committing.

[Prettier](https://prettier.io) is used to format TypeScript and Solidity code. Use it by running:

```
npm run format
```

[Solhint](https://protofire.github.io/solhint/) is used to lint Solidity files. Run it with:

```
npm run hint
```

### CI

A default Github Actions workflow is setup to execute on push and pull request.

It will build the contracts and run the test coverage.

You can modify it here: [.github/workflows/coverage.yml](.github/workflows/coverage.yml)

For the coverage to work, you will need to setup the `MAINNET_RPC_URL` repository secret in the settings of your Github repository.
