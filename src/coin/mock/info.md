# Notes

#### This is just a placeholder folder to keep mock USDSC and related token contracts for doing the tests. The actual would be imported from M0 repos to perform the tests.

#### Can be moved to foundry mocks.

#### We could deploy this on hub and spoke chains to interact with hub M token and make cross-chain transfer (mint and burn / transfer M like token) through hub.

#### progress

1. USDSC deployed on sepolia

forge test --match-path "test/fork/USDSC.fork.t.sol" -vv --fork-url https://ethereum-sepolia-rpc.publicnode.com
