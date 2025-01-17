#![cfg_attr(not(feature = "std"), no_std, no_main)]

use ink::{
    env::{DefaultEnvironment, Environment},
    primitives::AccountId,
};
use psp22::PSP22Error;

pub type Balance = <DefaultEnvironment as Environment>::Balance;

#[ink::trait_definition]
pub trait Mintable {
    #[ink(message)]
    fn mint(&mut self, to: AccountId, amount: Balance) -> Result<(), PSP22Error>;
}

#[ink::trait_definition]
pub trait Burnable {
    #[ink(message)]
    fn burn(&mut self, amount: Balance) -> Result<(), PSP22Error>;

    #[ink(message)]
    fn burn_from(&mut self, from: AccountId, amount: Balance) -> Result<(), PSP22Error>;
}
