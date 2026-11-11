const form = document.querySelector("#request-form");
const pickupDatesField = document.querySelector("#pickup-dates-field");
const deliveryAddressField = document.querySelector("#delivery-address-field");
const submissionMessage = document.querySelector("#submission-message");
const recipient = "page@tmservices.net";

form.addEventListener("change", (event) => {
  if (event.target.name !== "receivingMethod") {
    return;
  }

  const method = event.target.value;
  pickupDatesField.hidden = method !== "Pickup arranged by us";
  deliveryAddressField.hidden = method !== "Request delivery, if available";
});

form.addEventListener("submit", (event) => {
  event.preventDefault();

  const values = new FormData(form);
  const message = [
    `Organization Name: ${values.get("organizationName")}`,
    `EIN: ${values.get("ein")}`,
    "",
    `Contact Name: ${values.get("contactName")}`,
    `Email: ${values.get("email")}`,
    `Phone: ${values.get("phone") || "Not provided"}`,
    "",
    "Requested Item IDs and Quantities:",
    values.get("items"),
    "",
    `How they would like to receive the furniture: ${values.get("receivingMethod")}`,
    `Preferred pickup dates: ${values.get("preferredDates") || "Not provided"}`,
    `Delivery address: ${values.get("deliveryAddress") || "Not provided"}`,
    "",
    "Condition acknowledgment: I understand the furniture is used and provided as is, without warranties or guarantees. We can inspect it before accepting it and will decide whether it meets our needs."
  ].join("\n");
  const subject = `Furniture Donation Request - ${values.get("organizationName")}`;

  submissionMessage.textContent = "Your email app should open with your request. Send the email there to complete your request. Your request does not reserve items.";
  submissionMessage.hidden = false;
  window.location.href = `mailto:${recipient}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(message)}`;
});
