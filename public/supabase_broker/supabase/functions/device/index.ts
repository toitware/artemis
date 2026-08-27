import {
  anonymousClient,
  requireMethod,
  route,
  rpc,
  serve,
} from "../_shared/api.ts";

serve(async (req) => {
  const parts = route(req, "device").split("/").filter((part) => part !== "");
  if (parts.length !== 2) throw new Error("Invalid device URL");
  const [deviceId, operation] = parts;
  const supabase = anonymousClient();

  if (operation === "goal") {
    requireMethod(req, "GET");
    return rpc(supabase, "get_goal", { _device_id: deviceId });
  }
  if (operation === "state") {
    requireMethod(req, "PUT");
    return rpc(supabase, "update_state", {
      _device_id: deviceId,
      _state: await req.json(),
    }, true);
  }
  if (operation === "events") {
    requireMethod(req, "POST");
    const { type, data } = await req.json();
    return rpc(supabase, "report_event", {
      _device_id: deviceId,
      _type: type,
      _data: data,
    }, true);
  }
  throw new Error(`Unknown device operation: ${operation}`);
});
