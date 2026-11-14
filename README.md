# Heir — Smart Contracts

Non-custodial crypto inheritance protocol on Ethereum / EVM chains.

## Contracts

### `DigitalWill.sol`
Core inheritance contract — a dead man's switch for native coins and ERC-20 tokens. The testator deposits funds, names up to 20 heirs with custom shares (basis points) and chooses an inactivity period: 3, 6 or 12 months. Every testator action (check-in, deposit, withdrawal, changing heirs or the period) resets the timer. Only after the full period passes without any activity can anyone call `release()`, which credits each heir their share; heirs then collect independently (pull payments), so one broken heir address cannot block the others. Until `release()` is called, the testator can withdraw, check in or cancel at any time.

A one-time 1% fee is charged on deposits only. The owner can pause new deposits but cannot move user funds or block withdrawals, cancellation, release or claims.

### `FeeCollector.sol`
Protocol fee treasury. Receives deposit fees in native coins and ERC-20 tokens; the owner can withdraw them.

## Deployments

| Network      | Chain ID | DigitalWill | FeeCollector |
|--------------|----------|-------------|--------------|
| Ethereum     | 1        | [`0xfE4C9c1B63038aC51CD74A8D6a94EcABe269cD16`](https://etherscan.io/address/0xfE4C9c1B63038aC51CD74A8D6a94EcABe269cD16#code) | [`0xCE9f0f0da9Ee06dbcE253D0a0564Ed74B19606c4`](https://etherscan.io/address/0xCE9f0f0da9Ee06dbcE253D0a0564Ed74B19606c4#code) |
| Sepolia      | 11155111 | [`0xb780ac2e567f5550904F7dED2715aeaaE0312aD5`](https://sepolia.etherscan.io/address/0xb780ac2e567f5550904F7dED2715aeaaE0312aD5#code) | [`0xfE4C9c1B63038aC51CD74A8D6a94EcABe269cD16`](https://sepolia.etherscan.io/address/0xfE4C9c1B63038aC51CD74A8D6a94EcABe269cD16#code) |
| Polygon Amoy | 80002    | [`0xfE4C9c1B63038aC51CD74A8D6a94EcABe269cD16`](https://amoy.polygonscan.com/address/0xfE4C9c1B63038aC51CD74A8D6a94EcABe269cD16#code) | [`0xCE9f0f0da9Ee06dbcE253D0a0564Ed74B19606c4`](https://amoy.polygonscan.com/address/0xCE9f0f0da9Ee06dbcE253D0a0564Ed74B19606c4#code) |

All contracts are verified. Owner of every contract: Safe [`0x3Edd26179771A3Af92e82f2B52908f6dFB4AC1dA`](https://app.safe.global/home?safe=eth:0x3Edd26179771A3Af92e82f2B52908f6dFB4AC1dA) (same address on all three networks).

Compiled with Solidity 0.8.24, optimizer enabled (200 runs), OpenZeppelin Contracts 5.6.1.

## License

MIT
