use std::{collections::BTreeSet, sync::Arc};

use aleph_client::{
    contract::event::{BlockDetails, ContractEvent},
    utility::BlocksApi,
    AsConnection,
};
use ethers::{
    abi::{self, EncodePackedError, Token},
    core::types::Address,
    prelude::{ContractCall, ContractError},
    providers::{Middleware, ProviderError},
    utils::keccak256,
};
use log::{debug, error, info, warn};
use redis::{aio::Connection as RedisConnection, RedisError};
use subxt::utils::H256;
use thiserror::Error;
use tokio::{
    sync::{Mutex, OwnedSemaphorePermit, Semaphore},
    task::JoinHandle,
    time::{sleep, Duration},
};

use crate::{
    config::Config,
    connections::{
        azero::SignedAzeroWsConnection,
        eth::{EthConnection, EthConnectionError, SignedEthConnection},
        redis_helpers::{read_first_unprocessed_block_number, write_last_processed_block},
    },
    contracts::{
        get_request_event_data, AzeroContractError, CrosschainTransferRequestData, Most,
        MostInstance,
    },
    listeners::eth::{get_next_finalized_block_number_eth, ETH_BLOCK_PROD_TIME_SEC},
};

#[derive(Debug, Error)]
#[error(transparent)]
#[non_exhaustive]
pub enum AzeroListenerError {
    #[error("aleph-client error")]
    AlephClient(#[from] anyhow::Error),

    #[error("error when parsing ethereum address")]
    FromHex(#[from] rustc_hex::FromHexError),

    #[error("subxt error")]
    Subxt(#[from] subxt::Error),

    #[error("azero provider error")]
    Provider(#[from] ProviderError),

    #[error("azero contract error")]
    AzeroContract(#[from] AzeroContractError),

    #[error("eth connection error")]
    EthConnection(#[from] EthConnectionError),

    #[error("eth contract error")]
    EthContractListen(#[from] ContractError<EthConnection>),

    #[error("eth contract error")]
    EthContractTx(#[from] ContractError<SignedEthConnection>),

    #[error("no block found")]
    BlockNotFound,

    #[error("tx was not present in any block or mempool after the maximum number of retries")]
    TxNotPresentInBlockOrMempool,

    #[error("missing data from event")]
    MissingEventData(String),

    #[error("error when creating an ABI data encoding")]
    AbiEncode(#[from] EncodePackedError),

    #[error("redis connection error")]
    Redis(#[from] RedisError),

    #[error("unexpected error")]
    Unexpected,
}

const ALEPH_LAST_BLOCK_KEY: &str = "alephzero_last_known_block_number";
const ALEPH_BLOCK_PROD_TIME_SEC: u64 = 1;
// This is more than the maximum number of send_request calls than will fit into the block (execution time)
const ALEPH_MAX_REQUESTS_PER_BLOCK: usize = 50;

pub struct AlephZeroListener;

impl AlephZeroListener {
    pub async fn run(
        config: Arc<Config>,
        azero_connection: Arc<SignedAzeroWsConnection>,
        eth_connection: Arc<SignedEthConnection>,
        redis_connection: Arc<Mutex<RedisConnection>>,
    ) -> Result<(), AzeroListenerError> {
        let Config {
            azero_contract_metadata,
            azero_contract_address,
            azero_max_event_handler_tasks,
            name,
            default_sync_from_block_azero,
            ..
        } = &*config;

        let pending_blocks: Arc<Mutex<BTreeSet<u32>>> = Arc::new(Mutex::new(BTreeSet::new()));
        let event_handler_tasks_semaphore =
            Arc::new(Semaphore::new(*azero_max_event_handler_tasks));

        let most_instance = MostInstance::new(
            azero_contract_address,
            azero_contract_metadata,
            config.azero_ref_time_limit,
            config.azero_proof_size_limit,
        )?;
        let mut first_unprocessed_block_number = read_first_unprocessed_block_number(
            name.clone(),
            ALEPH_LAST_BLOCK_KEY.to_string(),
            redis_connection.clone(),
            *default_sync_from_block_azero,
        )
        .await;

        // Add the first block number to the set of pending blocks.
        add_to_pending(first_unprocessed_block_number, pending_blocks.clone()).await;

        // Main AlephZero event loop
        loop {
            // Query for the next unknowns finalized block number, if not present we wait for it.
            let to_block = get_next_finalized_block_number_azero(
                azero_connection.clone(),
                first_unprocessed_block_number,
            )
            .await;

            info!(
                "Processing events from blocks {} - {}",
                first_unprocessed_block_number, to_block
            );

            // Process events from the next unknown finalized block.
            for block_number in first_unprocessed_block_number..=to_block {
                // Add the next block number now, so that there is always some block number in the set.
                add_to_pending(block_number + 1, pending_blocks.clone()).await;

                let block_hash = azero_connection
                    .get_block_hash(block_number)
                    .await?
                    .ok_or(AzeroListenerError::BlockNotFound)?;

                let events = azero_connection
                    .as_connection()
                    .as_client()
                    .blocks()
                    .at(block_hash)
                    .await?
                    .events()
                    .await?;

                let filtered_events = most_instance.filter_events(
                    events,
                    BlockDetails {
                        block_number,
                        block_hash,
                    },
                );

                handle_events(
                    config.clone(),
                    eth_connection.clone(),
                    filtered_events,
                    block_number,
                    pending_blocks.clone(),
                    redis_connection.clone(),
                    event_handler_tasks_semaphore.clone(),
                )
                .await?;
            }

            // Update the last block number.
            first_unprocessed_block_number = to_block + 1;
        }
    }
}

async fn add_to_pending(block_number: u32, pending_blocks: Arc<Mutex<BTreeSet<u32>>>) {
    let mut pending_blocks = pending_blocks.lock().await;
    pending_blocks.insert(block_number);
}

// handle all events present in one block
async fn handle_events(
    config: Arc<Config>,
    eth_connection: Arc<SignedEthConnection>,
    events: Vec<ContractEvent>,
    block_number: u32,
    pending_blocks: Arc<Mutex<BTreeSet<u32>>>,
    redis_connection: Arc<Mutex<RedisConnection>>,
    event_handler_tasks_semaphore: Arc<Semaphore>,
) -> Result<(), AzeroListenerError> {
    let mut event_tasks = Vec::new();
    for event in events {
        let config = config.clone();
        let eth_connection = eth_connection.clone();
        let permit = event_handler_tasks_semaphore
            .clone()
            .acquire_owned()
            .await
            .expect("Failed to acquire semaphore permit");

        // Spawn a new task for handling each event.
        event_tasks.push(tokio::spawn(async move {
            handle_event(config, eth_connection, event, permit)
                .await
                .expect("Event handler failed");
        }));
        if event_tasks.len() >= ALEPH_MAX_REQUESTS_PER_BLOCK {
            panic!("Too many send_request calls in one block: our benchmark is outdated.");
        }
    }

    tokio::spawn(async move {
        handle_processed_block(
            config.clone(),
            block_number,
            event_tasks,
            pending_blocks.clone(),
            redis_connection.clone(),
        )
        .await
        .expect(
            "Failed to wait for event handler tasks or to update the last processed block number.",
        );
    });
    Ok(())
}

async fn handle_event(
    config: Arc<Config>,
    eth_connection: Arc<SignedEthConnection>,
    event: ContractEvent,
    _permit: OwnedSemaphorePermit,
) -> Result<(), AzeroListenerError> {
    let Config {
        committee_id,
        eth_contract_address,
        eth_tx_min_confirmations,
        eth_tx_submission_retries,
        ..
    } = &*config;
    if let Some(name) = &event.name {
        if name.eq("CrosschainTransferRequest") {
            let data = event.data;

            // decode event data
            let CrosschainTransferRequestData {
                dest_token_address,
                amount,
                dest_receiver_address,
                request_nonce,
            } = get_request_event_data(&data)?;

            info!(
                "Decoded event data: [dest_token_address: 0x{}, amount: {amount}, dest_receiver_address: 0x{}, request_nonce: {request_nonce}]", 
                hex::encode(dest_token_address),
                hex::encode(dest_receiver_address)
            );

            // NOTE: for some reason, ethers-rs's `encode_packed` does not properly encode the data
            // (it does not pad uint to 32 bytes, but uses the actual number of bytes required to store the value)
            // so we use `abi::encode` instead (it only differs for signed and dynamic size types, which we don't use here)
            let bytes = abi::encode(&[
                Token::Uint((*committee_id).into()),
                Token::FixedBytes(dest_token_address.to_vec()),
                Token::Uint(amount.into()),
                Token::FixedBytes(dest_receiver_address.to_vec()),
                Token::Uint(request_nonce.into()),
            ]);

            debug!("ABI event encoding: 0x{}", hex::encode(bytes.clone()));

            let request_hash = keccak256(bytes);

            info!("hashed event encoding: 0x{}", hex::encode(request_hash));

            let address = eth_contract_address.parse::<Address>()?;
            let contract = Most::new(address, eth_connection.clone());

            // forward transfer & vote
            let call: ContractCall<SignedEthConnection, ()> = contract.receive_request(
                request_hash,
                (*committee_id).into(),
                dest_token_address,
                amount.into(),
                dest_receiver_address,
                request_nonce.into(),
            );

            info!(
                "Sending tx with request nonce {} to the Ethereum network and waiting for {} confirmations",
                request_nonce,
                eth_tx_min_confirmations
            );

            // This shouldn't fail unless there is something wrong with our config.
            // NOTE: this does not check whether the actual tx reverted on-chain. Reverts are only checked on dry-run.
            let tx_hash = call
                .gas(config.eth_gas_limit)
                .send()
                .await?
                .confirmations(*eth_tx_min_confirmations)
                .retries(*eth_tx_submission_retries)
                .await?
                .ok_or(AzeroListenerError::TxNotPresentInBlockOrMempool)?
                .transaction_hash;

            info!("Tx with nonce {request_nonce} has been sent to the Ethereum network: {tx_hash:?} and received {eth_tx_min_confirmations} confirmations.");

            wait_for_eth_tx_finality(eth_connection, tx_hash).await?;
        }
    }
    Ok(())
}

// Awaits for all requests from the block to be processed, then updates the last processed block number in Redis.
async fn handle_processed_block(
    config: Arc<Config>,
    block_number: u32,
    event_tasks: Vec<JoinHandle<()>>,
    pending_blocks: Arc<Mutex<BTreeSet<u32>>>,
    redis_connection: Arc<Mutex<RedisConnection>>,
) -> Result<(), AzeroListenerError> {
    let Config { name, .. } = &*config;

    // Wait for all event processing tasks to finish.
    for task in event_tasks {
        task.await.expect("Event processing task has failed");
    }

    // Lock the pending blocks set and remove the current block number (as we managed to process all events from it).
    let mut pending_blocks = pending_blocks.lock().await;
    pending_blocks.remove(&block_number);

    // Now we know that all blocks before the pending block with the lowest number have been processed.
    // We can update the last processed block number in Redis.
    let earliest_still_pending = pending_blocks
        .first()
        .expect("There should always be a pending block in the set");

    // Note: `earliest_still_pending` will never be 0
    write_last_processed_block(
        name.clone(),
        ALEPH_LAST_BLOCK_KEY.to_string(),
        redis_connection,
        earliest_still_pending - 1,
    )
    .await?;

    Ok(())
}

pub async fn wait_for_eth_tx_finality(
    eth_connection: Arc<SignedEthConnection>,
    tx_hash: H256,
) -> Result<(), AzeroListenerError> {
    info!("Waiting for tx finality: {tx_hash:?}");
    loop {
        sleep(Duration::from_secs(ETH_BLOCK_PROD_TIME_SEC)).await;

        let finalized_head_number =
            get_next_finalized_block_number_eth(eth_connection.clone(), 0).await;

        match eth_connection.get_transaction(tx_hash).await {
            Ok(Some(tx)) => {
                if let Some(block_number) = tx.block_number {
                    if block_number <= finalized_head_number.into() {
                        info!("Eth tx {tx_hash:?} finalized");
                        return Ok(());
                    }
                }
            }
            Err(err) => {
                error!("Failed to get tx that should be present: {err}");
            }
            Ok(None) => panic!("Transaction {tx_hash:?} for which finality we were waiting is no longer included in the chain, aborting..."),
        };
    }
}

async fn get_next_finalized_block_number_azero(
    azero_connection: Arc<SignedAzeroWsConnection>,
    not_older_than: u32,
) -> u32 {
    loop {
        match azero_connection.get_finalized_block_hash().await {
            Ok(hash) => match azero_connection.get_block_number(hash).await {
                Ok(number_opt) => {
                    let best_finalized_block_number =
                        number_opt.expect("Finalized block should have a number.");
                    if best_finalized_block_number >= not_older_than {
                        return best_finalized_block_number;
                    }
                }
                Err(err) => {
                    warn!("Aleph Client error when getting best finalized block number: {err}");
                }
            },
            Err(err) => {
                warn!("Aleph Client error when getting best finalized block hash: {err}");
            }
        };

        // If we are up to date, we can sleep for a longer time.
        sleep(Duration::from_secs(10 * ALEPH_BLOCK_PROD_TIME_SEC)).await;
    }
}
