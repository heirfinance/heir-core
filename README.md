# Heir — Smart Contracts

Non-custodial crypto inheritance protocol on Ethereum / EVM chains.

## Contracts

### `DigitalWill.sol`
Core inheritance contract. Accepts ETH deposits and automatically releases funds to designated heirs if the owner stops checking in (30-day inactivity window). Supports multiple heirs with custom share splits (basis points), three lock periods (1 month / 1 year / 5 years), and a pull-based claim model to prevent a single heir from blocking others.

### `FeeCollector.sol`
Protocol fee treasury. Receives a small fee on each deposit, tracks total fees collected per token, and allows the owner to withdraw accumulated funds.

## Deployments

| Network         | Chain ID  | DigitalWill                                  | FeeCollector                                 |
|-----------------|-----------|----------------------------------------------|----------------------------------------------|
| Ethereum        | 1         | `0x326f2b13E828189A94Ef91B883fdE060104ee453` | `0x18F98966AB8D14e13A5230a92d7BC1485255B26f` |
| Sepolia         | 11155111  | `0x326f2b13E828189A94Ef91B883fdE060104ee453` | `0x18F98966AB8D14e13A5230a92d7BC1485255B26f` |
| Polygon Amoy    | 80002     | `0x326f2b13E828189A94Ef91B883fdE060104ee453` | `0x18F98966AB8D14e13A5230a92d7BC1485255B26f` |

## License

MIT