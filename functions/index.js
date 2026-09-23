const {setGlobalOptions} = require("firebase-functions");
const {initializeApp} = require("firebase-admin/app");

setGlobalOptions({maxInstances: 10});

initializeApp();

// This file is just wiring: each function group lives in its own domain
// module, and we re-export it here under its original name so the deployed
// function set stays stable.
const bridge = require("./bridge");
const places = require("./places");
const account = require("./account");
const employeeAccounts = require("./employee_accounts");
const maintenance = require("./maintenance");
const waveCallables = require("./wave/callables");
const waveTriggers = require("./wave/triggers");
const clientPropagation = require("./client_propagation");
const clientJobCount = require("./client_job_count");
const clients = require("./clients");
const clientBuildings = require("./client_buildings");
const appointmentImages = require("./appointment_images");
const notifications = require("./notifications");
const indexedSearch = require("./indexed_search");
const appointmentActions = require("./appointment_actions");

exports.syncUsersByUid = bridge.syncUsersByUid;
exports.propagateClientEdits = clientPropagation.propagateClientEdits;
exports.recountClientJobs = clientJobCount.recountClientJobs;
// Photos moving into appointments/{id}/images. The cascade is load-bearing:
// Firestore does not delete a subcollection with its parent, so without it
// every appointment delete leaves permanently orphaned photo documents.
exports.cascadeDeleteAppointmentImages =
  appointmentImages.cascadeDeleteAppointmentImages;
exports.recountAppointmentPictures =
  appointmentImages.recountAppointmentPictures;
exports.deleteClient = clients.deleteClient;
exports.syncClientBuilding = clientBuildings.syncClientBuilding;
exports.searchClients = indexedSearch.searchClients;
exports.searchHistory = indexedSearch.searchHistory;
exports.findAppointmentConflicts = indexedSearch.findAppointmentConflicts;
exports.restoreAppointmentStatus = appointmentActions.restoreAppointmentStatus;
exports.placesAutocomplete = places.placesAutocomplete;
exports.placesGetDetails = places.placesGetDetails;
exports.placesReverseGeocode = places.placesReverseGeocode;
exports.validateUploadedImage = maintenance.validateUploadedImage;
exports.deleteAccount = account.deleteAccount;
exports.createEmployeeAccount = employeeAccounts.createEmployeeAccount;
exports.completeEmployeeSetup = employeeAccounts.completeEmployeeSetup;
exports.deleteEmployeeAccount = employeeAccounts.deleteEmployeeAccount;
exports.changeEmployeeEmail = employeeAccounts.changeEmployeeEmail;
exports.purgeExpiredHistory = maintenance.purgeExpiredHistory;
exports.waveBootstrap = waveCallables.waveBootstrap;
exports.waveGetConnection = waveCallables.waveGetConnection;
exports.waveSetImportSchedule = waveCallables.waveSetImportSchedule;
exports.waveImportCustomers = waveCallables.waveImportCustomers;
exports.waveRetryFailedJobs = waveCallables.waveRetryFailedJobs;
exports.waveUpsertCustomer = waveTriggers.waveUpsertCustomer;
exports.notifyAppointmentChanges = notifications.notifyAppointmentChanges;
exports.sendUpcomingJobReminders = notifications.sendUpcomingJobReminders;
exports.sendDailyJobDigest = notifications.sendDailyJobDigest;
