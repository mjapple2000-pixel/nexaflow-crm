import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

Deno.serve(async (req) => {
  try {
    const formData = await req.formData();
    const callSid = formData.get("CallSid")?.toString() ?? "";
    const from = formData.get("From")?.toString() ?? "";
    const to = formData.get("To")?.toString() ?? "";

    // Look up business by the Twilio number that was called
    const { data: business, error } = await supabase
      .from("businesses")
      .select("id, ai_phone_number, owner_phone")
      .eq("ai_phone_number", to)
      .single();

    if (error || !business) {
      console.error("No business found for number:", to, error);
      return new Response(
        `<?xml version="1.0" encoding="UTF-8"?>
<Response><Hangup/></Response>`,
        { headers: { "Content-Type": "text/xml" } }
      );
    }

    // Look up contact by caller's phone number
    const { data: contact } = await supabase
      .from("contacts")
      .select("id")
      .eq("business_id", business.id)
      .eq("phone", from)
      .maybeSingle();

    // Insert call_log record (status pending — will be updated by status callback)
    await supabase.from("call_logs").insert({
      business_id: business.id,
      contact_id: contact?.id ?? null,
      phone_number_from: from,
      phone_number_to: to,
      call_status: "answered", // optimistic default; status callback overwrites if missed
      twilio_call_sid: callSid,
      reply_sent: false,
    });

    const statusCallbackUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/handle-call-status`;
    console.log("Dialing owner:", business.owner_phone, "statusCallbackUrl:", statusCallbackUrl);

    // TwiML: dial the owner's real phone, ring for 20s, then fire status callback
    const twiml = `<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Dial
    action="${statusCallbackUrl}"
    timeout="20"
    callerId="${to}">
    <Number statusCallbackEvent="initiated ringing answered completed" statusCallback="${statusCallbackUrl}">
      ${business.owner_phone}
    </Number>
  </Dial>
</Response>`;

    return new Response(twiml, {
      headers: { "Content-Type": "text/xml" },
    });
  } catch (err) {
    console.error("handle-inbound-call error:", err);
    return new Response(
      `<?xml version="1.0" encoding="UTF-8"?>
<Response><Hangup/></Response>`,
      { headers: { "Content-Type": "text/xml" } }
    );
  }
});