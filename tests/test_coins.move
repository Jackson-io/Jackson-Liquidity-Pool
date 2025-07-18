#[test_only]
module sui_jackson::test_usdc {
    use sui::coin::{Self, TreasuryCap, CoinMetadata};

    public struct TEST_USDC has drop {}

    #[test_only]
    public fun create_currency(ctx: &mut TxContext): (
        TreasuryCap<TEST_USDC>, 
        CoinMetadata<TEST_USDC>, 
    ) {
        coin::create_currency(
            TEST_USDC {}, 
            6, 
            vector::empty(),
            vector::empty(),
            vector::empty(),
            option::none(),
            ctx
        )
    }
}

#[test_only]
module sui_jackson::test_sui {
    use sui::coin::{Self, TreasuryCap, CoinMetadata};

    public struct TEST_SUI has drop {}

    #[test_only]
    public fun create_currency(ctx: &mut TxContext): (
        TreasuryCap<TEST_SUI>, 
        CoinMetadata<TEST_SUI>, 
    ) {
        coin::create_currency(
            TEST_SUI {}, 
            9, 
            vector::empty(),
            vector::empty(),
            vector::empty(),
            option::none(),
            ctx
        )
    }
}


#[test_only]
module sui_jackson::mock_metadata {
    use sui::bag::{Bag, Self};
    use sui_jackson::test_usdc::{TEST_USDC, Self};
    use sui_jackson::test_sui::{TEST_SUI, Self};
    use std::type_name::{Self};
    use sui::coin::{CoinMetadata};
    use sui::test_utils::{Self};

    public struct Metadata {
        metadata: Bag
    }

    public fun init_metadata(ctx: &mut TxContext): Metadata {
        let mut bag = bag::new(ctx);

        let (test_usdc_cap, test_usdc_metadata) = test_usdc::create_currency(ctx);
        let (test_sui_cap, test_sui_metadata) = test_sui::create_currency(ctx);

        test_utils::destroy(test_usdc_cap);
        test_utils::destroy(test_sui_cap);

        bag::add(&mut bag, type_name::get<TEST_USDC>(), test_usdc_metadata);
        bag::add(&mut bag, type_name::get<TEST_SUI>(), test_sui_metadata);

        Metadata {
            metadata: bag
        }
    }

    public fun get<T>(metadata: &Metadata): &CoinMetadata<T> {
        bag::borrow(&metadata.metadata, type_name::get<T>())
    }
}
