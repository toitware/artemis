import {
  client,
  parameter,
  requireMethod,
  route,
  rpc,
  rpcParameters,
  serve,
} from "../_shared/api.ts";

serve(async (req) => {
  const path = route(req, "pod-store");
  const supabase = client(req);

  if (path === "/parts" || path === "/manifests") {
    const url = new URL(req.url);
    const scope = parameter(url, "scope");
    const id = parameter(url, "id");
    const kind = path === "/parts" ? "part" : "manifest";
    const storagePath = `${scope}/${kind}/${id}`;
    if (req.method === "PUT") {
      const { error } = await supabase.storage.from("toit-artemis-pods").upload(
        storagePath,
        await req.arrayBuffer(),
        { upsert: true, contentType: "application/octet-stream" },
      );
      if (error) throw new Error(error.message);
      return null;
    }
    requireMethod(req, "GET");
    const { data, error } = await supabase.storage.from("toit-artemis-pods")
      .download(storagePath);
    if (error) throw new Error(error.message);
    return new Response(await data.arrayBuffer(), {
      headers: { "Content-Type": "application/octet-stream" },
    });
  }

  const body = await req.json();
  let rpcName: string;
  if (path === "/descriptions" && req.method === "PUT") {
    rpcName = "upsert_pod_description";
  } else if (path === "/descriptions" && req.method === "DELETE") {
    rpcName = "delete_pod_descriptions";
  } else if (path === "/pods" && req.method === "POST") rpcName = "insert_pod";
  else if (path === "/pods" && req.method === "DELETE") rpcName = "delete_pods";
  else if (path === "/tags" && req.method === "PUT") rpcName = "set_pod_tag";
  else if (path === "/tags" && req.method === "DELETE") {
    rpcName = "delete_pod_tag";
  } else if (path === "/references/resolve" && req.method === "POST") {
    rpcName = "get_pods_by_reference";
  } else if (path === "/descriptions/query" && req.method === "POST") {
    const query = body.query;
    delete body.query;
    if (query === "fleet") rpcName = "get_pod_descriptions";
    else if (query === "ids") rpcName = "get_pod_descriptions_by_ids";
    else if (query === "names") rpcName = "get_pod_descriptions_by_names";
    else throw new Error(`Unknown description query: ${query}`);
  } else if (path === "/pods/query" && req.method === "POST") {
    const query = body.query;
    delete body.query;
    if (query === "description") rpcName = "get_pods";
    else if (query === "ids") rpcName = "get_pods_by_ids";
    else throw new Error(`Unknown pod query: ${query}`);
  } else throw new Error(`Unknown pod-store route: ${req.method} ${path}`);

  return rpc(supabase, rpcName, rpcParameters(body), true);
});
