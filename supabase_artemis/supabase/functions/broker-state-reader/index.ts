import {
  client,
  requireMethod,
  route,
  rpc,
  rpcParameters,
  serve,
} from "../_shared/api.ts";

serve(async (req) => {
  const path = route(req, "broker-state-reader");
  requireMethod(req, "POST");
  if (path !== "/devices/query") {
    throw new Error(`Unknown broker-state-reader route: ${path}`);
  }
  return rpc(client(req), "get_devices", rpcParameters(await req.json()));
});
