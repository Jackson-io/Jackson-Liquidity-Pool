module sui_jackson::reserve;

use std::type_name::{Self, TypeName};

use sui::dynamic_field::{Self};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::event::{Self};

use pyth::price_info::{PriceInfoObject};
use pyth::price_identifier::{PriceIdentifier};

use sui_jackson::oracles;
use sui_jackson::decimal::{Self, Decimal, mul, div, min, max};

// === Constants ===
const PRICE_STALENESS_THRESHOLD_S: u64 = 0;

// === Errors ===
const EPriceStale: u64 = 0;
const EPriceIdentifierMismatch: u64 = 1;
const EInvalidPrice: u64 = 2;
const EWrongType: u64 = 3;

// === public structs ===
public struct Reserve has key, store {
    id: UID,
    
    array_index: u64,
    coin_type: TypeName,
    mint_decimals: u8,
    
    available_amount: u64,

    // oracles
    price_identifier: PriceIdentifier,

    price: Decimal,
    smoothed_price: Decimal,
    price_last_update_timestamp_s: u64,
}


public struct Balances<phantom T> has store {
    available_amount: Balance<T>,
    fees: Balance<T>,
}

// === Dynamic Field Keys ===
public struct BalanceKey has copy, drop, store {}

// === Events ===
public struct ReserveAssetDataEvent has drop, copy {
    coin_type: TypeName,
    reserve_id: address,
    available_amount: Decimal,

    price: Decimal,
    smoothed_price: Decimal,
    price_last_update_timestamp_s: u64,
}

public(package) fun create_reserve<T>(
    array_index: u64,
    mint_decimals: u8,
    price_info_obj: &PriceInfoObject, 
    clock: &Clock,
    ctx: &mut TxContext
): Reserve {
    let (mut price_decimal, smoothed_price_decimal, price_identifier) = oracles::get_pyth_price_and_identifier(price_info_obj, clock);

    let mut reserve = Reserve {
        id: object::new(ctx),
        array_index,
        coin_type: type_name::get<T>(),
        mint_decimals,

        available_amount: 0,

        price_identifier,
        price: option::extract(&mut price_decimal),
        smoothed_price: smoothed_price_decimal,
        price_last_update_timestamp_s: clock::timestamp_ms(clock) / 1000,
    };

    dynamic_field::add(
        &mut reserve.id,
        BalanceKey {},
        Balances<T> {
            available_amount: balance::zero<T>(),
            fees: balance::zero<T>(),
        }
    );

    reserve
}


// === Public-Mutative Functions

public(package) fun update_price(
    reserve: &mut Reserve, 
    clock: &Clock,
    price_info_obj: &PriceInfoObject
) {
    let (mut price_decimal, ema_price_decimal, price_identifier) = oracles::get_pyth_price_and_identifier(price_info_obj, clock);
    assert!(price_identifier == reserve.price_identifier, EPriceIdentifierMismatch);
    assert!(option::is_some(&price_decimal), EInvalidPrice);

    reserve.price = option::extract(&mut price_decimal);
    reserve.smoothed_price = ema_price_decimal;
    reserve.price_last_update_timestamp_s = clock::timestamp_ms(clock) / 1000;
}

public(package) fun change_price_feed(
    reserve: &mut Reserve,
    price_info_obj: &PriceInfoObject,
    clock: &Clock,
) {
    let (_, _, price_identifier) = oracles::get_pyth_price_and_identifier(price_info_obj, clock);
    reserve.price_identifier = price_identifier;
}

public(package) fun receive_token<T>(
    reserve: &mut Reserve, 
    token: Balance<T>,
) {
    assert!(coin_type(reserve) == std::type_name::get<T>(), EWrongType);

    reserve.available_amount = reserve.available_amount + balance::value(&token);

    log_reserve_data(reserve);

    let balances: &mut Balances<T> = dynamic_field::borrow_mut(
        &mut reserve.id, 
        BalanceKey {}
    );

    balance::join(&mut balances.available_amount, token);
}

public(package) fun back_token<T>(
    reserve: &mut Reserve, 
    token_amount: u64,
): Balance<T> {
    assert!(coin_type(reserve) == std::type_name::get<T>(), EWrongType);
    reserve.available_amount = reserve.available_amount - token_amount;

    log_reserve_data(reserve);

    let balances: &mut Balances<T> = dynamic_field::borrow_mut(
        &mut reserve.id, 
        BalanceKey {}
    );

    balance::split(&mut balances.available_amount, token_amount)
}

public(package) fun receive_fee<T>(
    reserve: &mut Reserve, 
    fee: Balance<T>,
) {
    assert!(coin_type(reserve) == std::type_name::get<T>(), EWrongType);

    let balances: &mut Balances<T> = dynamic_field::borrow_mut(
        &mut reserve.id, 
        BalanceKey {}
    );

    balance::join(&mut balances.fees, fee);
}

public(package) fun claim_fees<T>(
    reserve: &mut Reserve,
): Balance<T> {
    let balances: &mut Balances<T> = dynamic_field::borrow_mut(&mut reserve.id, BalanceKey {});
    let fees = balance::withdraw_all(&mut balances.fees);
    fees
}

// === Public-View Functions ===

public fun price_identifier(reserve: &Reserve): &PriceIdentifier {
    &reserve.price_identifier
}

public fun array_index(reserve: &Reserve): u64 {
    reserve.array_index
}

public fun available_amount(reserve: &Reserve): u64 {
    reserve.available_amount
}

public fun coin_type(reserve: &Reserve): TypeName {
    reserve.coin_type
}

public fun price(reserve: &Reserve): Decimal {
    reserve.price
}

public fun price_lower_bound(reserve: &Reserve): Decimal {
    min(reserve.price, reserve.smoothed_price)
}

public fun price_upper_bound(reserve: &Reserve): Decimal {
    max(reserve.price, reserve.smoothed_price)
}

public fun balances<T>(reserve: &Reserve): &Balances<T> {
    dynamic_field::borrow(&reserve.id, BalanceKey {})
}

public use fun balances_available_amount as Balances.available_amount;
public fun balances_available_amount<T>(balances: &Balances<T>): &Balance<T> {
    &balances.available_amount
}

public use fun balances_fees as Balances.fees;
public fun balances_fees<T>(balances: &Balances<T>): &Balance<T> {
    &balances.fees
}

public fun token_amount_to_usd(
    reserve: &Reserve, 
    token_amount: Decimal
): Decimal {
    div(
        mul(
            price(reserve),
            token_amount
        ),
        decimal::from(std::u64::pow(10, reserve.mint_decimals))
    )
}

public fun token_amount_to_usd_lower_bound(
    reserve: &Reserve, 
    token_amount: Decimal
): Decimal {
    div(
        mul(
            price_lower_bound(reserve),
            token_amount
        ),
        decimal::from(std::u64::pow(10, reserve.mint_decimals))
    )
}

public fun token_amount_to_usd_upper_bound(
    reserve: &Reserve, 
    token_amount: Decimal
): Decimal {
    div(
        mul(
            price_upper_bound(reserve),
            token_amount
        ),
        decimal::from(std::u64::pow(10, reserve.mint_decimals))
    )
}

public fun usd_to_token_amount(
    reserve: &Reserve, 
    usd_amount: Decimal
): Decimal {
    div(
        mul(
            decimal::from(std::u64::pow(10, reserve.mint_decimals)),
            usd_amount
        ),
        price(reserve)
    )
}

public fun usd_to_token_amount_lower_bound(
    reserve: &Reserve, 
    usd_amount: Decimal
): Decimal {
    div(
        mul(
            decimal::from(std::u64::pow(10, reserve.mint_decimals)),
            usd_amount
        ),
        price_upper_bound(reserve)
    )
}

public fun usd_to_token_amount_upper_bound(
    reserve: &Reserve, 
    usd_amount: Decimal
): Decimal {
    div(
        mul(
            decimal::from(std::u64::pow(10, reserve.mint_decimals)),
            usd_amount
        ),
        price_lower_bound(reserve)
    )
}

// make sure we are using the latest published price on sui
public fun assert_price_is_fresh(reserve: &Reserve, clock: &Clock) {
    let cur_time_s = clock::timestamp_ms(clock) / 1000;
    assert!(
        cur_time_s - reserve.price_last_update_timestamp_s <= PRICE_STALENESS_THRESHOLD_S,
        EPriceStale
    );
}

// === Private Functions ===
fun log_reserve_data(reserve: &Reserve){
    let available_amount_decimal = decimal::from(reserve.available_amount);

    event::emit(ReserveAssetDataEvent {
        coin_type: reserve.coin_type,
        reserve_id: object::uid_to_address(&reserve.id),
        available_amount: available_amount_decimal,
        
        price: reserve.price,
        smoothed_price: reserve.smoothed_price,
        price_last_update_timestamp_s: reserve.price_last_update_timestamp_s,
    });
}


// === Test Functions ===
#[test_only]
public fun update_price_for_testing(
    reserve: &mut Reserve, 
    clock: &Clock,
    price_decimal: Decimal,
    smoothed_price_decimal: Decimal
) {
    reserve.price = price_decimal;
    reserve.smoothed_price = smoothed_price_decimal;
    reserve.price_last_update_timestamp_s = clock::timestamp_ms(clock) / 1000;
}