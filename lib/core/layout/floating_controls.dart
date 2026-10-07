/// Bottom gap a list must leave when its host floats controls over it.
///
/// The calendar's FAB and Today pill, and the clients list's FAB and its
/// back-to-top button, all sit 16px above the bottom of the body — so without
/// it the LAST row scrolls to a rest position underneath them and can neither
/// be read nor tapped.
const double kFloatingControlsClearance = 90;
