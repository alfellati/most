NETWORK ?= development
AZERO_ENV ?= dev

export BRIDGENET_START_BLOCK=`ENDPOINT=https://rpc-fe-bridgenet.dev.azero.dev ./relayer/scripts/azero_best_finalized.sh`
export CONTRACT_VERSION ?=`git rev-parse HEAD`

.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#'  Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done

.PHONY: clean-azero
clean-azero: # Remove azero node data
clean-azero:
	cd devnet-azero && rm -rf \
		5*/chains/a0dnet1/db \
		5*/chains/a0dnet1/network \
		5*/backup-stash \
		5*/chainspec.json
	rm -rf azero/artifacts/*
	echo "Done azero clean"

.PHONY: clean-eth
clean-eth: # Remove eth node data
clean-eth:
	cd devnet-eth && ./clean.sh && echo "Done devnet-eth clean"
	cd eth && rm -rf .openzeppelin && echo "Done eth clean"

.PHONY: clean
clean: # Remove all node data
clean: stop-local-bridgenet clean-azero clean-eth

.PHONY: bootstrap-azero
bootstrap-azero: # Bootstrap the node data
bootstrap-azero:
	cd devnet-azero && \
	cp azero_chainspec.json 5D34dL5prEUaGNQtPPZ3yN5Y6BnkfXunKXXz6fo7ZJbLwRRH/chainspec.json

.PHONY: devnet-azero
devnet-azero: # Run azero devnet
devnet-azero: bootstrap-azero
	docker compose -f ./devnet-azero/devnet-azero-compose.yml up -d

.PHONY: devnet-eth
devnet-eth: # Run eth devnet
devnet-eth:
	docker compose -f ./devnet-eth/devnet-eth-compose.yml up -d

.PHONY: redis-instance
redis-instance: # Run a redis instance
redis-instance:
	docker compose -f ./relayer/scripts/redis-compose.yml up -d

.PHONY: local-bridgenet
local-bridgenet: # Run both devnets + a redis instance
local-bridgenet: devnet-azero devnet-eth redis-instance

.PHONY: stop-local-bridgenet
stop-local-bridgenet:
stop-local-bridgenet: stop-relayers
	docker compose -f ./devnet-azero/devnet-azero-compose.yml down && \
	docker compose -f ./devnet-eth/devnet-eth-compose.yml down && \
	docker compose -f ./relayer/scripts/redis-compose.yml down

.PHONY: eth-deps
eth-deps: # Install eth dependencies
eth-deps:
	cd eth && npm install

.PHONY: watch-eth
watch-eth: # watcher on the eth contracts
watch-eth:
	cd eth && npm run watch

.PHONY: compile-eth
compile-eth: # Compile eth contracts
compile-eth: eth-deps
	cd eth && npx hardhat compile

.PHONY: deploy-eth
deploy-eth: # Deploy eth contracts
deploy-eth: compile-eth
	cd eth && \
	npx hardhat run --network $(NETWORK) scripts/1_deploy_contracts.js

.PHONY: setup-eth
setup-eth: # Setup eth contracts
setup-eth: compile-eth
	cd eth && \
	npx hardhat run --network $(NETWORK) scripts/2_setup_contracts.js

.PHONY: most-builder
most-builder: # Build an image in which contracts can be built
most-builder:
	docker build -t most-builder -f docker/most_builder.dockerfile .

.PHONY: compile-azero-docker
compile-azero-docker: # Compile azero contracts in docker
compile-azero-docker: azero-deps most-builder
	docker run --rm --network host \
		--volume "$(shell pwd)":/code \
		--workdir /code \
		--name most-builder \
		most-builder \
		make compile-azero

.PHONY: deploy-azero-docker
deploy-azero-docker: # Deploy azero contracts compiling in docker
deploy-azero-docker: azero-deps compile-azero-docker
	cd azero && npm run deploy

.PHONY: azero-deps
azero-deps: # Install azero dependencies
azero-deps:
	cd azero && npm install

.PHONY: watch-azero
watch-azero: # watch azero contracts and generate artifacts
watch-azero:
	cd azero && npm run watch

.PHONY: compile-azero
compile-azero: # compile azero contracts and generate artifacts
compile-azero: azero-deps
	cd azero && npm run compile

.PHONY: deploy-azero
deploy-azero: # Deploy azero contracts
deploy-azero: compile-azero
	cd azero && npm run deploy

.PHONY: deploy
deploy: # Deploy all contracts
deploy: deploy-azero deploy-eth

.PHONY: watch-relayer
watch-relayer:
	cd relayer && cargo watch -s 'cargo clippy' -c

run-relayers: # Run the relayer
run-relayers: build-docker-relayer
	docker compose -f ./relayer/scripts/devnet-relayers-compose.yml up -d

.PHONY: stop-relayers
stop-relayers:
	docker compose -f ./relayer/scripts/devnet-relayers-compose.yml down

.PHONY: bridge
bridge: # Run the bridge
bridge: local-bridgenet deploy run-relayers devnet-relayers-logs

.PHONY: bridgenet-bridge
bridgenet-bridge: # Run the bridge on bridgenet
bridgenet-bridge: build-docker-relayer redis-instance
	NETWORK=bridgenet AZERO_ENV=bridgenet make deploy
	AZERO_START_BLOCK=${BRIDGENET_START_BLOCK} docker-compose -f ./relayer/scripts/bridgenet-relayers-compose.yml up -d
	make bridgenet-relayers-logs

.PHONY: devnet-relayers-logs
devnet-relayers-logs: # Show the logs of the devnet relayers
devnet-relayers-logs:
	docker compose -f ./relayer/scripts/devnet-relayers-compose.yml logs -f

.PHONY: bridgenet-relayers-logs
bridgenet-relayers-logs: # Show the logs of the bridgenet relayers
bridgenet-relayers-logs:
	docker compose -f ./relayer/scripts/bridgenet-relayers-compose.yml logs -f

.PHONY: test-solidity
test-solidity: # Run solidity tests
test-solidity: eth-deps
	cd eth && npx hardhat test ./test/Most.js ./test/WrappedEther.js

.PHONY: test-ink-e2e
test-ink-e2e: # Run ink e2e tests
test-ink-e2e: bootstrap-azero
	export CONTRACTS_NODE="../../scripts/azero_contracts_node.sh" && \
	cd azero/contracts/tests && \
	cargo test e2e -- --test-threads=1 --nocapture

.PHONY: test-ink
test-ink: # Run ink tests
test-ink: test-ink-e2e
	cd azero/contracts/most && cargo test
	cd azero/contracts/governance && cargo test
	cd azero/contracts/token && cargo test
	cd azero/contracts/gas-price-oracle/contract && cargo test
	cd azero/contracts/gas-price-oracle/test-contract && cargo test

.PHONY: check-js-format
check-js-format: # Check js formatting
check-js-format:
	cd eth && npx prettier --check test

.PHONY: solidity-lint
solidity-lint: # Lint solidity contracts
solidity-lint: eth-deps
	cd eth && npx solium -d contracts

.PHONY: relayer-lint
relayer-lint: # Lint relayer
relayer-lint: compile-azero-docker compile-eth
	cd relayer && cargo clippy -- --no-deps -D warnings

.PHONY: ink-lint
ink-lint: # Lint ink contracts
ink-lint:
	cd azero/contracts/most && cargo clippy -- --no-deps -D warnings
	cd azero/contracts/governance && cargo clippy -- --no-deps -D warnings
	cd azero/contracts/token && cargo clippy -- --no-deps -D warnings
	cd azero/contracts/psp22-traits && cargo clippy -- --no-deps -D warnings
	cd azero/contracts/tests && cargo clippy -- --no-deps -D warnings
	cd azero/contracts/gas-price-oracle/contract && cargo clippy -- --no-deps -D warnings
	cd azero/contracts/gas-price-oracle/test-contract && cargo clippy -- --no-deps -D warnings
	cd azero/contracts/gas-price-oracle/trait && cargo clippy -- --no-deps -D warnings

.PHONY: contracts-lint
contracts-lint: # Lint contracts
contracts-lint: solidity-lint ink-lint

.PHONY: rust-format-check
rust-format-check: # Check rust code formatting
rust-format-check:
	cd relayer && cargo fmt -- --check
	cd azero/contracts/most && cargo fmt -- --check
	cd azero/contracts/governance && cargo fmt -- --check
	cd azero/contracts/token && cargo fmt -- --check
	cd azero/contracts/psp22-traits && cargo fmt -- --check
	cd azero/contracts/tests && cargo fmt -- --check
	cd azero/contracts/gas-price-oracle/contract && cargo fmt -- --check
	cd azero/contracts/gas-price-oracle/test-contract && cargo fmt -- --check
	cd azero/contracts/gas-price-oracle/trait && cargo fmt -- --check

.PHONY: rust-format
rust-format: # Format rust code
rust-format:
	cd relayer && cargo fmt
	cd azero/contracts/most && cargo fmt
	cd azero/contracts/governance && cargo fmt
	cd azero/contracts/token && cargo fmt
	cd azero/contracts/psp22-traits && cargo fmt
	cd azero/contracts/tests && cargo fmt
	cd azero/contracts/gas-price-oracle/contract && cargo fmt
	cd azero/contracts/gas-price-oracle/test-contract && cargo fmt
	cd azero/contracts/gas-price-oracle/trait && cargo fmt

.PHONY: js-format-check
js-format-check: # Check js formatting
js-format-check:
	cd eth && npx prettier --check test
	cd eth && npx prettier --check scripts
	cd eth && npx prettier --check hardhat.config.js
	cd azero && npx prettier --check scripts

.PHONY: js-format
js-format: # Format js code
js-format:
	cd eth && npx prettier --write test
	cd eth && npx prettier --write scripts
	cd eth && npx prettier --write hardhat.config.js
	cd azero && npx prettier --write scripts

.PHONY: format-check
format-check: # Check code formatting
format-check: rust-format-check js-format-check

.PHONY: format
format: # Format code
format: rust-format js-format

.PHONY: build-docker-relayer
build-docker-relayer: # Build relayer docker image
build-docker-relayer: compile-azero compile-eth
	cd relayer && cargo build --release
	cp azero/addresses.json relayer/azero_addresses.json
	cp eth/addresses.json relayer/eth_addresses.json
	cp azero/artifacts/most.json relayer/most.json
	cd relayer && docker build -t most-relayer .
	rm relayer/azero_addresses.json relayer/eth_addresses.json relayer/most.json

contract_spec.json: # Generate a a file describing deployed contracts based on addresses.json files
contract_spec.json: azero/addresses.json eth/addresses.json
	VERSION=${CONTRACT_VERSION} node scripts/contract_spec.js > contract_spec.json
