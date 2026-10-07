/// Minutes an appointment's start and end snap to — :00, :15, :30, :45.
///
/// Jobs here are booked and invoiced by the quarter hour, so a picker that
/// offers all 60 minutes offers 45 answers nobody wants and makes two
/// appointments that start a minute apart look like a scheduling mistake.
const int appointmentMinuteStep = 15;
