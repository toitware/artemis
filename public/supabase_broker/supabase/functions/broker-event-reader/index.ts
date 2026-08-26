import {
  client,
  requireMethod,
  route,
  rpc,
  rpcParameters,
  serve,
} from "../_shared/api.ts";

serve(async (req) => {
  const path = route(req, "broker-event-reader");
  requireMethod(req, "POST");
  if (path !== "/events/query") {
    throw new Error(`Unknown broker-event-reader route: ${path}`);
  }
  return rpc(client(req), "get_events", rpcParameters(await req.json()));
});
