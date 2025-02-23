module sui_jackson::admin;

public struct AdminCap has key, store {
    id: UID,
}

public struct HandlerCap has key, store {
    id: UID,
}

public struct WithdrawCap has key, store {
    id: UID,
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(
        AdminCap{
            id: object::new(ctx)
        },
        tx_context::sender(ctx)
    );
}


// === Admin Functions ===
public fun create_handler_cap(
    _: &AdminCap,
    ctx: &mut TxContext,
): HandlerCap {
    HandlerCap {
        id: object::new(ctx)
    }
}

public fun del_handler_cap(
    _: &AdminCap, 
    handler_cap: HandlerCap,
) {
    let HandlerCap { id } = handler_cap;
    id.delete();
}

public fun create_withdraw_cap(
    _: &AdminCap, 
    ctx: &mut TxContext,
): WithdrawCap {
    WithdrawCap {
        id: object::new(ctx)
    }
}

public fun del_withdraw_cap(
    _: &AdminCap, 
    withdraw_cap: WithdrawCap,
) {
    let WithdrawCap { id } = withdraw_cap;
    id.delete();
}


// === Test Functions ===
#[test_only]
public fun create_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap{
        id: object::new(ctx)
    }
}