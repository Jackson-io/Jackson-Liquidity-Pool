module sui_jackson::recharge_test;

use std::type_name::{Self};

use sui::test_scenario::{Self, Scenario};
use sui::coin::{Self};
use sui::bag::{Self, Bag};
use sui::test_utils::{Self};

use sui_jackson::admin::{Self, AdminCap, WithdrawCap};
use sui_jackson::recharge::{Self, Recharge};

public struct State<phantom T> {
    recharge: Recharge<T>,
    admin_cap: AdminCap,
    withdraw_cap: WithdrawCap,
    type_to_index: Bag,
}

#[test_only]
fun setup<T>(scenario: &mut Scenario): State<T> {
    use sui_jackson::test_usdc::{TEST_USDC};
    use sui_jackson::mock_metadata::{Self};

    let admin_cap = admin::create_for_testing(test_scenario::ctx(scenario));
    let withdraw_cap = admin::create_withdraw_cap(&admin_cap, test_scenario::ctx(scenario));
    let recharge = recharge::create_for_testing<T>(test_scenario::ctx(scenario));

    let metadata = mock_metadata::init_metadata(test_scenario::ctx(scenario));

    let mut type_to_index = bag::new(test_scenario::ctx(scenario));
    bag::add(&mut type_to_index, type_name::get<TEST_USDC>(), 0);

    test_utils::destroy(metadata);

    return State { recharge, admin_cap, withdraw_cap, type_to_index }
}

#[test]
fun test_deposit() {
    use sui_jackson::test_usdc::{TEST_USDC};

    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));

    let State { mut recharge, admin_cap, withdraw_cap, type_to_index} = setup<TEST_USDC>(&mut scenario);
    
    recharge::pub_deposit<TEST_USDC>(&mut recharge, coins, owner, test_scenario::ctx(&mut scenario));

    test_utils::destroy(admin_cap);
    test_utils::destroy(withdraw_cap);
    test_utils::destroy(recharge);
    test_utils::destroy(type_to_index); 
    test_scenario::end(scenario);
}

#[test]
fun test_withdraw() {
    use sui_jackson::test_usdc::{TEST_USDC};

    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let coin_amount = 100 * 1_000_000;
    let coins = coin::mint_for_testing<TEST_USDC>(coin_amount, test_scenario::ctx(&mut scenario));

    let State { mut recharge, admin_cap, withdraw_cap, type_to_index} = setup<TEST_USDC>(&mut scenario);
    recharge::pub_deposit<TEST_USDC>(&mut recharge, coins, owner, test_scenario::ctx(&mut scenario));
    
    let withdraw_coin = recharge::admin_withdraw<TEST_USDC>(&withdraw_cap, &mut recharge, coin_amount, test_scenario::ctx(&mut scenario));

    test_utils::destroy(admin_cap);
    test_utils::destroy(withdraw_cap);
    test_utils::destroy(recharge);
    test_utils::destroy(type_to_index); 
    test_utils::destroy(withdraw_coin); 
    test_scenario::end(scenario);
}