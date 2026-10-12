use pointer_input_ffi::{
    PointerInputStatusV3, pointer_input_engine_create_v3, pointer_input_engine_destroy_v3,
};
use std::{panic::catch_unwind, ptr, sync::mpsc};

#[test]
fn panicking_hook_create_fails_before_install_then_normal_create_succeeds() {
    // ponytail: this binary exits after installing the test-owned hook wrapper.
    let _previous_hook = std::panic::take_hook();
    let (sender, receiver) = mpsc::channel();
    std::panic::set_hook(Box::new(move |_| {
        let mut owner = ptr::null_mut();
        let status = unsafe { pointer_input_engine_create_v3(&raw mut owner) };
        let _ = sender.send((status, owner.is_null()));
    }));

    assert!(catch_unwind(|| panic!("test panic before hook installation")).is_err());
    assert_eq!(
        receiver.recv().expect("prior hook must call create"),
        (PointerInputStatusV3::Panic, true)
    );

    let mut owner = ptr::null_mut();
    assert_eq!(
        unsafe { pointer_input_engine_create_v3(&raw mut owner) },
        PointerInputStatusV3::Success
    );
    assert_eq!(
        unsafe { pointer_input_engine_destroy_v3(&raw mut owner) },
        PointerInputStatusV3::Success
    );
}
