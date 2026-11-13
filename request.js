const form = document.querySelector("#request-form");
const pickupDatesField = document.querySelector("#pickup-dates-field");
const deliveryAddressField = document.querySelector("#delivery-address-field");
const submissionMessage = document.querySelector("#submission-message");
const recipient = "page@tmservices.net";
const endpoint = "https://api.web3forms.com/submit";
const accessKey = "e2de8ec1-ab34-480d-9e3f-56f73d361967";

form.addEventListener("change", (event) => {
  if (event.target.name !== "receivingMethod") {
    return;
  }

  const method = event.target.value;
  pickupDatesField.hidden = method !== "Pickup arranged by requester";
  deliveryAddressField.hidden = method !== "Request delivery, if available";
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  const values = new FormData(form);
  if (values.get("botcheck")) {
    return;
  }
  const message = [
    `Organization Name: ${values.get("organizationName")}`,
    `EIN: ${values.get("ein") || "Not provided"}`,
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

  const submitButton = form.querySelector(".submit-button");
  submitButton.disabled = true;
  submissionMessage.textContent = "Sending your request...";
  submissionMessage.hidden = false;

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({
        access_key: accessKey,
        subject,
        from_name: values.get("organizationName"),
        name: values.get("contactName"),
        email: values.get("email"),
        message
      })
    });
    const result = await response.json();
    if (!response.ok || !result.success) {
      throw new Error(result.message || "Request failed");
    }
    form.reset();
    pickupDatesField.hidden = true;
    deliveryAddressField.hidden = true;
    submissionMessage.textContent = "Thank you! Your request was sent to T&M Services. We will contact you to confirm availability. Your request does not reserve items.";
  } catch (error) {
    submissionMessage.textContent = `We could not send your request. Please try again or email ${recipient} directly.`;
  } finally {
    submitButton.disabled = false;
  }
});
