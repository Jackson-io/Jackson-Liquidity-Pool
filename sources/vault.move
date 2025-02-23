module sui_jackson::vault;

use std::type_name::{Self, TypeName};
use sui::coin::{Self, Coin, CoinMetadata};
use sui::balance::{Self, Supply, Balance};
use sui::clock::{Clock};
use sui::event::{Self};

use pyth::price_info::{PriceInfoObject};

use sui_jackson::admin::{AdminCap, HandlerCap};
use sui_jackson::reserve::{Self, Reserve};
use sui_jackson::recharge::{Self, Recharge};
use sui_jackson::decimal::{Self, Decimal, add, mul, div, ceil};
use sui_jackson::cell::{Self, Cell};

// === Constants ===
const CURRENT_VERSION: u64 = 1;
const DEFAULT_LIQUIDITY_FEE_BASIS_POINTS: u64 = 30; // 0.3%

// === Errors ===
const EIncorrectVersion: u64 = 1;
const EDuplicateReserve: u64 = 2;
const EWrongType: u64 = 3;
const EInvalidVaultConfig: u64 = 4;

public struct Vault has key, store {
    id: UID,

    version: u64,

    reserves: vector<Reserve>,

    usdj: u64,

    usdj_supply: Supply<USDJ>,
    
    config: Cell<VaultConfig>,
}

public struct VaultConfig has store {
    fees: FeesConfig,
}

public struct FeesConfig has store {
    liquidity_fee_basis_points: u64,
}

public struct USDJ has drop {}


public struct BuyUSDJEvent has drop, copy {
    coin_type: TypeName,
    usdj_amount: u64,
    coin_amount: u64,
    fee_amount: u64,
    fee_basis_points: Decimal,
}

public struct SellUSDJEvent has drop, copy {
    coin_type: TypeName,
    usdj_amount: u64,
    coin_amount: u64,
    fee_amount: u64,
    fee_basis_points: Decimal,
}

public struct SettleEvent has drop, copy {
    sender: address,
    coin_type: TypeName,
    amount: u64,
    isIn: bool,
}

fun init(ctx: &mut TxContext) {
    let config = VaultConfig {
        fees: FeesConfig {
            liquidity_fee_basis_points: DEFAULT_LIQUIDITY_FEE_BASIS_POINTS
        }
    };

    validate_vault_config(&config);
    let vault = Vault<> {
        id: object::new(ctx),
        version: CURRENT_VERSION,
        reserves: vector::empty(),
        usdj: 0,
        usdj_supply: balance::create_supply(USDJ {}),
        config: cell::new(config)
    };
    transfer::share_object(vault)
}

// === Public-Mutative Functions ===
public fun refresh_reserve_price(
    vault: &mut Vault,
    reserve_array_index: u64,
    clock: &Clock,
    price_info: &PriceInfoObject,
) {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    let reserve = vector::borrow_mut(&mut vault.reserves, reserve_array_index);
    reserve::update_price(reserve, clock, price_info);
}

public(package) fun buy_usdj<T>(
    vault: &mut Vault,
    reserve_array_index: u64,
    deposit: Coin<T>,
    clock: &Clock, 
): Balance<USDJ> {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    let deposit_amount = coin::value(&deposit);
    let mut deposit_balance = coin::into_balance(deposit);
    let liquidity_fee_basis_points = liquidity_fee_basis_points(config(vault));

    let reserve = vector::borrow_mut(&mut vault.reserves, reserve_array_index);
    reserve::assert_price_is_fresh(reserve, clock);

    let fee_amount = ceil(mul(liquidity_fee_basis_points, decimal::from(deposit_amount)));
    reserve::receive_fee(reserve, balance::split(&mut deposit_balance, fee_amount));

    let usd = reserve.token_amount_to_usd_lower_bound(decimal::from(deposit_amount - fee_amount));

    let usdj_amount = decimal::floor(mul(decimal::from(1000000), usd));

    vault.usdj = vault.usdj + usdj_amount;

    reserve::receive_token(reserve, deposit_balance);
    let usdjs = balance::increase_supply(
            &mut vault.usdj_supply,
            usdj_amount
        );

    event::emit(BuyUSDJEvent {
        coin_type: type_name::get<T>(),
        usdj_amount,
        coin_amount: deposit_amount,
        fee_amount,
        fee_basis_points: liquidity_fee_basis_points,
    });
    usdjs
}

public(package) fun sell_usdj<T>(
    vault: &mut Vault,
    reserve_array_index: u64,
    usdj: Coin<USDJ>,
    clock: &Clock, 
) : Balance<T> {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    let liquidity_fee_basis_points = liquidity_fee_basis_points(config(vault));
    let reserve = vector::borrow_mut(&mut vault.reserves, reserve_array_index);
    
    let usdj_amount = coin::value(&usdj);
    let usdj_coin = coin::into_balance(usdj);

    reserve::assert_price_is_fresh(reserve, clock);

    vault.usdj = vault.usdj - usdj_amount;

    balance::decrease_supply(
            &mut vault.usdj_supply,
            usdj_coin
        );

    let token_decimal = reserve.usd_to_token_amount_lower_bound(div(decimal::from(usdj_amount), decimal::from(1000000)));

    let token_amount = decimal::floor(token_decimal);

    let mut back_token_balance =  reserve::back_token<T>(reserve, token_amount);
    
    let fee_amount = ceil(mul(liquidity_fee_basis_points, decimal::from(token_amount)));
    reserve::receive_fee(reserve, balance::split(&mut back_token_balance, fee_amount));

    event::emit(SellUSDJEvent {
        coin_type: type_name::get<T>(),
        usdj_amount,
        coin_amount: balance::value(&back_token_balance),
        fee_amount,
        fee_basis_points: liquidity_fee_basis_points,
    });
    back_token_balance
}

public(package) fun increase_usdj(
    vault: &mut Vault,
    usdj_amount: u64
): Balance<USDJ>{
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    vault.usdj = vault.usdj + usdj_amount;
    let usdjs = balance::increase_supply(
            &mut vault.usdj_supply,
            usdj_amount
        );
    usdjs
}

// === Public-View Functions ===

// slow function. use sparingly.
fun reserve_array_index<T>(vault: &Vault): u64 {
    let mut i = 0;
    while (i < vector::length(&vault.reserves)) {
        let reserve = vector::borrow(&vault.reserves, i);
        if (reserve::coin_type(reserve) == std::type_name::get<T>()) {
            return i
        };

        i = i + 1;
    };

    i
}

public fun reserves(vault: &Vault): &vector<Reserve> {
    &vault.reserves
}

public fun get_aum(
    vault: &Vault,
    maximise: bool,
    clock: &Clock
): u64 {
    let mut i = 0;
    let mut aum = decimal::from(0);
    while (i < vector::length(&vault.reserves)) {
        let reserve = vector::borrow(&vault.reserves, i);
        
        reserve::assert_price_is_fresh(reserve, clock);
        let mut usd;
        
        if (maximise) {
            usd = reserve.token_amount_to_usd_upper_bound((decimal::from(reserve.available_amount())));
        } else {
            usd = reserve.token_amount_to_usd_lower_bound(decimal::from(reserve.available_amount()));
        };
        
        aum = add(aum, usd);

        i = i + 1;
    };

    let aum_amount = decimal::floor(decimal::mul(decimal::from(1000000), aum));
    aum_amount
}

public fun config(vault: &Vault): &VaultConfig {
    cell::get(&vault.config)
}

public fun liquidity_fee_basis_points(config: &VaultConfig): Decimal {
    decimal::from_bps(config.fees.liquidity_fee_basis_points)
}

// === Admin Functions ===
entry fun migrate(_: &AdminCap, vault: &mut Vault) {
    assert!(vault.version <= CURRENT_VERSION - 1, EIncorrectVersion);
    vault.version = CURRENT_VERSION;
}

public fun add_reserve<T>(
    _: &AdminCap, 
    vault: &mut Vault, 
    coin_metadata: &CoinMetadata<T>,
    price_info_obj: &PriceInfoObject, 
    clock: &Clock, 
    ctx: &mut TxContext
) {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    assert!(reserve_array_index<T>(vault) == vector::length(&vault.reserves), EDuplicateReserve);

    let reserve = reserve::create_reserve<T>(
        vector::length(&vault.reserves),
        coin::get_decimals(coin_metadata),
        
        price_info_obj,
        clock,
        ctx
    );

    vector::push_back(&mut vault.reserves, reserve);
}

public fun change_reserve_price_feed<T>(
    _: &AdminCap, 
    vault: &mut Vault,
    reserve_array_index: u64,
    price_info_obj: &PriceInfoObject,
    clock: &Clock,
) {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    let reserve = vector::borrow_mut(&mut vault.reserves, reserve_array_index);
    assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

    reserve::change_price_feed(reserve, price_info_obj, clock);
}

public fun create_vault_config(
    vault: &Vault,
    liquidity_fee_basis_points: u64,
): VaultConfig {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    let config = VaultConfig {
        fees: FeesConfig {
            liquidity_fee_basis_points: liquidity_fee_basis_points
        }
    };

    validate_vault_config(&config);
    config
}

fun validate_vault_config(config: &VaultConfig) {
    assert!(config.fees.liquidity_fee_basis_points <= 10_000, EInvalidVaultConfig);
}

public fun update_vault_config(
    _: &AdminCap,
    vault: &mut Vault,
    config: VaultConfig, 
) {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    let old = cell::set(&mut vault.config, config);
    let VaultConfig {
        fees: FeesConfig {
            liquidity_fee_basis_points: _
        },
    } = old;
}

public fun admin_settle<T>(
    _: &HandlerCap,
    vault: &mut Vault,
    recharge: &mut Recharge<T>,
    reserve_array_index: u64,
    amount: u64,
    isIn: bool,
    ctx: &mut TxContext
) {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    let reserve = vector::borrow_mut(&mut vault.reserves, reserve_array_index);
    if (isIn) {
        let coin = recharge::withdraw<T>(recharge, amount, true);
        reserve::receive_token(reserve, coin);
    } else {
        let coin_balance = reserve::back_token<T>(reserve, amount);
        let coin = coin::from_balance(coin_balance, ctx);
        recharge::deposit<T>(recharge, coin, @0x00,true, ctx);
    };
    
    event::emit(SettleEvent {
        sender: tx_context::sender(ctx),
        coin_type: type_name::get<T>(),
        amount,
        isIn,
    });
}

public fun claim_fees<T>(
    _: &AdminCap,
    vault: &mut Vault,
    reserve_array_index: u64,
): Balance<T> {
    assert!(vault.version == CURRENT_VERSION, EIncorrectVersion);
    let reserve = vector::borrow_mut(&mut vault.reserves, reserve_array_index);
    assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

    let fees = reserve::claim_fees(reserve);
    fees
}

// === Test Functions ===
#[test_only]
public fun create_for_testing(ctx: &mut TxContext): Vault {
    let config = VaultConfig {
        fees: FeesConfig {
            liquidity_fee_basis_points: DEFAULT_LIQUIDITY_FEE_BASIS_POINTS
        }
    };

    validate_vault_config(&config);
    Vault<> {
        id: object::new(ctx),
        version: CURRENT_VERSION,
        reserves: vector::empty(),
        usdj: 0,
        usdj_supply: balance::create_supply(USDJ {}),
        config: cell::new(config)
    }
}