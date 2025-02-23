module sui_jackson::recharge;

use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::event::{Self};
use std::type_name::{Self, TypeName};

use sui_jackson::admin::{AdminCap, WithdrawCap};

const EWrongType: u64 = 1;

public struct Recharge<phantom T> has key, store {
    id: UID,

    coin_type: TypeName,

    available_amount: u64,    
    available_balance: Balance<T>,
}

// === Events ===
public struct DepositEvent has drop, copy {
    sender: address,
    account: address,
    coin_type: TypeName,
    deposit_amount: u64,
    is_inner: bool,
}

public struct WithdrawEvent has drop, copy {
    coin_type: TypeName,
    withdraw_amount: u64,
    is_inner: bool,
}

// === Public-View Functions ===
public fun coin_type<T>(reserve: &Recharge<T>): TypeName {
    reserve.coin_type
}


// === Public-Mutative Functions
public fun pub_deposit<T>(
    recharge: &mut Recharge<T>,
    coin: Coin<T>,
    account: address,
    ctx: &mut TxContext
) {
    deposit(recharge, coin, account, false, ctx);
}

public(package) fun deposit<T>(
    recharge: &mut Recharge<T>,
    coin: Coin<T>,
    account: address,
    is_inner: bool,
    ctx: &TxContext
) {
    assert!(coin_type<T>(recharge) == std::type_name::get<T>(), EWrongType);
    let sender = tx_context::sender(ctx);

    let coin_amount = coin::value(&coin);

    recharge.available_amount = recharge.available_amount + coin_amount;
    let coin_balance = coin::into_balance(coin);
    balance::join(&mut recharge.available_balance, coin_balance);

    event::emit(DepositEvent {
        sender: sender,
        account: account,
        coin_type: type_name::get<T>(),
        deposit_amount: coin_amount,
        is_inner
    });
}

public(package) fun withdraw<T>(
    recharge: &mut Recharge<T>,
    withdraw_amount: u64,
    is_inner: bool,
): Balance<T> {
    assert!(coin_type<T>(recharge) == std::type_name::get<T>(), EWrongType);

    recharge.available_amount = recharge.available_amount - withdraw_amount;
    
    event::emit(WithdrawEvent {
        is_inner,
        coin_type: type_name::get<T>(),
        withdraw_amount
    });

    balance::split(&mut recharge.available_balance, withdraw_amount)
}


// === Admin Functions ===
public fun create_recharge<T>(
    _: &AdminCap,
    ctx: &mut TxContext
) {
    let recharge = Recharge<T> {
        id: object::new(ctx),
        coin_type: type_name::get<T>(),
        available_amount: 0,
        available_balance: balance::zero<T>(),
    };
    transfer::share_object(recharge)
}

public fun admin_withdraw<T>(
    _: &WithdrawCap,
    recharge: &mut Recharge<T>,
    withdraw_amount: u64,
    ctx: &mut TxContext
): Coin<T> {
    let coin_balance = withdraw(recharge, withdraw_amount, false);
    let coin = coin::from_balance(coin_balance, ctx);

    coin
}

// === Test Functions ===
#[test_only]
public fun create_for_testing<T>(ctx: &mut TxContext): Recharge<T> {
    Recharge<T> {
        id: object::new(ctx),
        coin_type: type_name::get<T>(),
        available_amount: 0,
        available_balance: balance::zero<T>(),
    }
}