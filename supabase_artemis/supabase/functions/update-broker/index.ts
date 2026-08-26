import {
  client,
  requireMethod,
  route,
  rpc,
  rpcParameters,
  serve,
} from "../_shared/api.ts";

serve(async (req) => {
  const path = route(req, "update-broker");
  const body = await req.json();
  const supabase = client(req);

  if (path === "/goal") {
    requireMethod(req, "PUT");
    return rpc(supabase, "set_goal", rpcParameters(body), true);
  }
  if (path === "/goals") {
    requireMethod(req, "PUT");
    return rpc(supabase, "set_goals", rpcParameters(body));
  }
  if (path === "/devices") {
    requireMethod(req, "POST");
    const { device_id, organization_id, state } = body;
    const { error } = await client(req, "public").from("devices").insert({
      id: device_id,
      alias: device_id,
      organization_id,
    });
    if (error) throw new Error(error.message);
    return rpc(supabase, "new_provisioned", {
      _device_id: device_id,
      _state: state,
    }, true);
  }
  throw new Error(`Unknown update-broker route: ${path}`);
});
