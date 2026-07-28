/// The five modes from spec Section 6. One enum drives Rive, brightness, and
/// camera/inference throttling together so they can never drift out of sync.
enum PetState { tracking, idle, dimming, sleeping, waking }
