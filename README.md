## TrailHook

TrailHook is a trailing order hook for Uniswap V4. It allows users to place trailing orders, which are orders that automatically adjust their execution price based on the market price (trailing the market price).

# How it works

This can be used to automatically sell or buy a token when the price reaches a certain level. The user sets the trailing distance and the direction of the order (buy or sell). The order is executed when the price reaches the trailing distance from the initial price.

# Key Concepts

-   **Trailing Order**: An order that automatically adjusts its execution price based on the market price.
-   **Trailing Distance**: The distance from the initial price that the order will trail.
-   **Direction**: The direction of the order (buy or sell).
-   **Reference Price**: The price at which the the trailing starts. It can be the price at which the order was placed or a specific price that the user wants to use as a reference price.
-   **Market Price**: The current price of the token.



DISCLAIMER: This code was produced within the scope of the Uniswap V4 Incubator program. It is not audited and should not be used in production.



## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
