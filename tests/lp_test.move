module sui_jackson::lp_test;

use std::type_name::{Self};

use sui::test_scenario::{Self, Scenario};
use sui::coin::{Self};
use sui::bag::{Self, Bag};
use sui::test_utils::{Self};
use sui::clock::{Self, Clock};

use sui_jackson::admin::{Self, AdminCap};
use sui_jackson::vault::{Self, Vault};
use sui_jackson::reserve::{Self};
use sui_jackson::lp_manager::{Self, LiquidityPool, Liquidity};
use sui_jackson::mock_pyth::{Self, PriceState};

public struct State {
    clock: Clock,
    pool: LiquidityPool,
    liquidity: Liquidity,
    vault: Vault,
    admin_cap: AdminCap,
    prices: PriceState,
    type_to_index: Bag,
}

#[test_only]
fun setup(scenario: &mut Scenario): State {
    use sui_jackson::test_usdc::{TEST_USDC};
    use sui_jackson::test_sui::{TEST_SUI};
    use sui_jackson::mock_metadata::{Self};

    let pool= lp_manager::create_for_testing((test_scenario::ctx(scenario)));
    let liquidity= lp_manager::create_liquidity(&pool, test_scenario::ctx(scenario));
    let admin_cap = admin::create_for_testing((test_scenario::ctx(scenario)));
    let mut vault = vault::create_for_testing((test_scenario::ctx(scenario)));

    let clock = clock::create_for_testing(test_scenario::ctx(scenario));
    let metadata = mock_metadata::init_metadata(test_scenario::ctx(scenario));

    let mut type_to_index = bag::new(test_scenario::ctx(scenario));
    bag::add(&mut type_to_index, type_name::get<TEST_USDC>(), 0);
    
    let mut prices = mock_pyth::init_state(test_scenario::ctx(scenario));
    mock_pyth::register<TEST_USDC>(&mut prices, test_scenario::ctx(scenario));
    mock_pyth::register<TEST_SUI>(&mut prices, test_scenario::ctx(scenario));
    vault::add_reserve<TEST_USDC>(
        &admin_cap,
        &mut vault,
        mock_metadata::get<TEST_USDC>(&metadata),
        mock_pyth::get_price_obj<TEST_USDC>(&prices),
        &clock,
        test_scenario::ctx(scenario)
    );
    test_utils::destroy(metadata);

    return State { clock, pool, liquidity, vault, admin_cap, prices, type_to_index }
}

#[test]
fun test_update_vault_config() {
    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let State { clock, pool, liquidity, admin_cap, mut vault, prices, type_to_index} = setup(&mut scenario);
    
    let config = vault::create_vault_config(&vault, 50);
    vault::update_vault_config(&admin_cap, &mut vault, config);
    
    std::debug::print(&vault);
    test_utils::destroy(clock);
    test_utils::destroy(admin_cap);
    test_utils::destroy(pool);
    test_utils::destroy(vault);
    test_utils::destroy(type_to_index); 
    test_utils::destroy(prices);
    test_utils::destroy(liquidity);
    test_scenario::end(scenario);
}

#[test]
fun test_add_liquidity() {
    use sui_jackson::test_usdc::{TEST_USDC};

    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));

    let State { clock, mut pool, mut liquidity, admin_cap, mut vault, mut prices, type_to_index} = setup(&mut scenario);
    
    mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    vault::refresh_reserve_price(
        &mut vault,
        *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
        &clock,
        mock_pyth::get_price_obj<TEST_USDC>(&prices)
    );

    let liquidity_amount = lp_manager::add_liquidity<TEST_USDC>(&mut pool, &mut liquidity, coins, &mut vault, 0, &clock, test_scenario::ctx(&mut scenario));

    let reserve = vector::borrow(vault::reserves(&vault), 0);
    let balances = reserve::balances<TEST_USDC>(reserve);
    
    let glp_price = lp_manager::glp_price(&pool, &vault, true, &clock);

    std::debug::print(&liquidity_amount);
    std::debug::print(&liquidity);
    std::debug::print(&vault);
    std::debug::print(balances);
    std::debug::print(&glp_price);
    std::debug::print_stack_trace();
    test_utils::destroy(clock);
    test_utils::destroy(admin_cap);
    test_utils::destroy(pool);
    test_utils::destroy(vault);
    test_utils::destroy(type_to_index); 
    test_utils::destroy(prices);
    test_utils::destroy(liquidity);
    test_scenario::end(scenario);
}

#[test]
fun test_remove_liquidity() {
    use sui_jackson::test_usdc::{TEST_USDC};

    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));

    let State { mut clock, mut pool, mut liquidity, admin_cap, mut vault, mut prices, type_to_index} = setup(&mut scenario);
    
    mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    vault::refresh_reserve_price(
        &mut vault,
        *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
        &clock,
        mock_pyth::get_price_obj<TEST_USDC>(&prices)
    );
    
    let liquidity_amount = lp_manager::add_liquidity<TEST_USDC>(&mut pool, &mut liquidity, coins, &mut vault, 0, &clock, test_scenario::ctx(&mut scenario));
    std::debug::print(&liquidity_amount);

    clock::increment_for_testing(&mut clock, 15 * 60 * 1000 + 1000);
    mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    vault::refresh_reserve_price(
        &mut vault,
        *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
        &clock,
        mock_pyth::get_price_obj<TEST_USDC>(&prices)
    );

    let coin = lp_manager::remove_liquidity<TEST_USDC>(&mut pool, &mut liquidity, &mut vault, 0, 1_000_000, &clock, test_scenario::ctx(&mut scenario));

    let reserve = vector::borrow(vault::reserves(&vault), 0);
    let balances = reserve::balances<TEST_USDC>(reserve);
    
    let glp_price = lp_manager::glp_price(&pool, &vault, true, &clock);

    std::debug::print(&coin);
    std::debug::print(&liquidity);
    std::debug::print(&vault);
    std::debug::print(balances);
    std::debug::print(&glp_price);
    std::debug::print_stack_trace();
    test_utils::destroy(clock);
    test_utils::destroy(admin_cap);
    test_utils::destroy(pool);
    test_utils::destroy(liquidity);
    test_utils::destroy(vault);
    test_utils::destroy(type_to_index); 
    test_utils::destroy(prices);
    test_utils::destroy(coin);
    test_scenario::end(scenario);
}


#[test]
fun test_claim_fees() {
    use sui_jackson::test_usdc::{TEST_USDC};

    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));

    let State { clock, mut pool, mut liquidity, admin_cap, mut vault, mut prices, type_to_index} = setup(&mut scenario);
    
    mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    vault::refresh_reserve_price(
        &mut vault,
        *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
        &clock,
        mock_pyth::get_price_obj<TEST_USDC>(&prices)
    );

    let liquidity_amount = lp_manager::add_liquidity<TEST_USDC>(&mut pool, &mut liquidity, coins, &mut vault, 0, &clock, test_scenario::ctx(&mut scenario));


    let fees = vault::claim_fees<TEST_USDC>(&admin_cap, &mut vault, 0);

    let reserve = vector::borrow(vault::reserves(&vault), 0);
    let balances = reserve::balances<TEST_USDC>(reserve);

    std::debug::print(&liquidity_amount);
    std::debug::print(&liquidity);
    std::debug::print(&vault);
    std::debug::print(balances);
    std::debug::print(&fees);
    std::debug::print_stack_trace();
    test_utils::destroy(clock);
    test_utils::destroy(admin_cap);
    test_utils::destroy(pool);
    test_utils::destroy(vault);
    test_utils::destroy(type_to_index); 
    test_utils::destroy(prices);
    test_utils::destroy(liquidity);
    test_utils::destroy(fees);
    test_scenario::end(scenario);
}
