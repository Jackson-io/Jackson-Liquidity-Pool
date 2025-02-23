module sui_jackson::lp_manager;

use sui::coin::{Self, Coin};
use sui::balance::{Self, Supply, Balance};
use sui::clock::{Self, Clock};
use sui::event::{Self};
use std::type_name::{Self, TypeName};

use sui_jackson::admin::{AdminCap, HandlerCap};
use sui_jackson::vault::{Self, Vault, USDJ};
use sui_jackson::decimal::{Self, floor, mul, div};

// === Constants ===
const CURRENT_VERSION: u64 = 1;
const COOL_DOWN_DURATION: u64 = 15 * 60;

// === Errors ===
const EIncorrectVersion: u64 = 1;
const ETooSmall: u64 = 2;
const EPoolPause: u64 = 3;
const ECoolDownDuration: u64 = 4;

// === public structs ===
public struct Liquidity_Coin has drop{}

public struct Liquidity has key, store {
    id: UID,
    last_add_timestamp: u64,

    liquidity_balance: Balance<Liquidity_Coin>
}

public struct LiquidityPool has key, store {
    id: UID,

    version: u64,

    lp_supply: Supply<Liquidity_Coin>,

    usdj_available_amount: u64,
    
    usdj_available_balance: Balance<USDJ>,
    
    pause: bool,
}

// === Events ===
public struct SetPauseEvent has copy, drop {
    sender: address,
    pause: bool
}

public struct AddLiquidityEvent has drop, copy {
    sender: address,
    coin_type: TypeName,
    coin_amount: u64,
    usdj_amount: u64,
    liquidity_amount: u64,
}

public struct RemoveLiquidityEvent has drop, copy {
    sender: address,
    coin_type: TypeName,
    coin_amount: u64,
    usdj_amount: u64,
    liquidity_amount: u64,
}

// Init Function
fun init(ctx: &mut TxContext) {
    let pool = make_pool(
        ctx);
    transfer::share_object(pool);
}

fun make_pool(
    ctx: &mut TxContext
): LiquidityPool {
    let lp_supply = balance::create_supply(Liquidity_Coin {});

    LiquidityPool {
        id: object::new(ctx),
        version: CURRENT_VERSION,
        lp_supply,
        usdj_available_amount: 0,
        usdj_available_balance: balance::zero(),
        pause: false,
    }
}

// === Public-Mutative Functions
public fun create_liquidity(
    pool: &LiquidityPool,
    ctx: &mut TxContext
): Liquidity {
    assert!(pool.version == CURRENT_VERSION, EIncorrectVersion);
    Liquidity {
        id: object::new(ctx),
        last_add_timestamp: 0,
        liquidity_balance: balance::zero()
    }
}

public fun add_liquidity<T>(
    pool: &mut LiquidityPool,
    liquidity: &mut Liquidity,
    coin: Coin<T>,
    vault: &mut Vault,
    reserve_array_index: u64,
    clock: &Clock,
    ctx: &mut TxContext
): u64 {
    assert!(pool.version == CURRENT_VERSION, EIncorrectVersion);
    assert_pause(pool);

    let cur_time_s = clock::timestamp_ms(clock) / 1000;
    liquidity.last_add_timestamp = cur_time_s;

    let coin_amount = coin::value(&coin);

    let aum = vault::get_aum(vault, true, clock);

    let usdjs = vault::buy_usdj(vault, reserve_array_index, coin, clock);
    
    let usdj_amount = balance::value(&usdjs);
    assert!(balance::value(&usdjs) > 0, ETooSmall);
    
    pool.usdj_available_amount = pool.usdj_available_amount + balance::value(&usdjs);
    
    balance::join(&mut pool.usdj_available_balance, usdjs);

    let lp_supply_amount = balance::supply_value(&pool.lp_supply);
    let liquidity_mint_amount = if (aum == 0) {
        usdj_amount
    } else {
        floor(
            div(
                mul(
                    decimal::from(usdj_amount),
                    decimal::from(lp_supply_amount)
                ),
                decimal::from(aum)
            )
        )
    };

    let liquidity_balance = balance::increase_supply(
        &mut pool.lp_supply,
        liquidity_mint_amount
    );
    balance::join(&mut liquidity.liquidity_balance, liquidity_balance);

    event::emit(AddLiquidityEvent {
        sender: tx_context::sender(ctx),
        coin_type: type_name::get<T>(),
        coin_amount,
        usdj_amount,
        liquidity_amount: liquidity_mint_amount,
    });

    liquidity_mint_amount
}

public fun remove_liquidity<T>(
    pool: &mut LiquidityPool,
    liquidity: &mut Liquidity,
    vault: &mut Vault,
    reserve_array_index: u64,
    liquidity_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<T> {
    assert!(pool.version == CURRENT_VERSION, EIncorrectVersion);
    assert_pause(pool);
    let cur_time_s = clock::timestamp_ms(clock) / 1000;
    assert!(
        cur_time_s - liquidity.last_add_timestamp > COOL_DOWN_DURATION,
        ECoolDownDuration
    );
    let aum = vault::get_aum(vault, false, clock);

    let lp_supply_amount = balance::supply_value(&pool.lp_supply);
    let usdj_amount = 
        floor(
            div(
                mul(
                    decimal::from(liquidity_amount),
                    decimal::from(aum)
                ),
                decimal::from(lp_supply_amount)
            )
        );

    if (usdj_amount > pool.usdj_available_amount) {
        let usdjs = vault::increase_usdj(vault, usdj_amount - pool.usdj_available_amount);
        pool.usdj_available_amount = pool.usdj_available_amount + balance::value(&usdjs);
        
        balance::join(&mut pool.usdj_available_balance, usdjs);
    };
    
    let usdj_balance = balance::split(&mut pool.usdj_available_balance, usdj_amount);
    pool.usdj_available_amount = pool.usdj_available_amount - balance::value(&usdj_balance);

    let coin_balance = vault::sell_usdj<T>(vault, reserve_array_index, coin::from_balance(usdj_balance, ctx), clock);
    assert!(balance::value(&coin_balance) > 0, ETooSmall);

    let liquidity_balance = balance::split(&mut liquidity.liquidity_balance, liquidity_amount);
    balance::decrease_supply(
        &mut pool.lp_supply,
        liquidity_balance
    );

    let coin = coin::from_balance(coin_balance, ctx);
    let coin_amount = coin::value(&coin);

    event::emit(RemoveLiquidityEvent {
        sender: tx_context::sender(ctx),
        coin_type: type_name::get<T>(),
        coin_amount,
        usdj_amount,
        liquidity_amount,
    });

    coin
}

// === Public-View Functions ===
public fun get_pause_status(pool: &LiquidityPool): bool {
    pool.pause
}

public fun glp_price(
    pool: &LiquidityPool,
    vault: &Vault,
    maximise: bool,
    clock: &Clock
): u64 {
    let aum = vault::get_aum(vault, maximise, clock);
    let lp_supply_amount = balance::supply_value(&pool.lp_supply);
    let glp_price = 
        floor(
            div(
                mul(
                    decimal::from(1_000_000),
                    decimal::from(aum)
                ),
                decimal::from(lp_supply_amount)
            )
        );
    glp_price
}

fun assert_pause(pool: &LiquidityPool) {
    assert!(
        !get_pause_status(pool),
        EPoolPause);
}

// === Admin Functions ===
entry fun migrate(_: &AdminCap, pool: &mut LiquidityPool) {
    assert!(pool.version <= CURRENT_VERSION - 1, EIncorrectVersion);
    pool.version = CURRENT_VERSION;
}

public fun set_pause_status(
    _: &HandlerCap,
    pool: &mut LiquidityPool,
    pause: bool,
    ctx: &mut TxContext
) {
    assert!(pool.version == CURRENT_VERSION, EIncorrectVersion);
    pool.pause = pause;
    event::emit(SetPauseEvent{
        sender: tx_context::sender(ctx),
        pause
    });
}

// === Test Functions ===
#[test_only]
public fun create_for_testing(ctx: &mut TxContext): LiquidityPool {
    make_pool(ctx)
}
