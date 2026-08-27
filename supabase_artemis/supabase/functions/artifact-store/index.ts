import {
  client,
  parameter,
  requireMethod,
  route,
  serve,
} from "../_shared/api.ts";

serve(async (req) => {
  const path = route(req, "artifact-store");
  const url = new URL(req.url);
  const scope = parameter(url, "scope");
  const supabase = client(req);

  if (path === "/images") {
    requireMethod(req, "PUT");
    const appId = parameter(url, "app_id");
    const wordSize = parameter(url, "word_size");
    const { error } = await supabase.storage.from("toit-artemis-assets").upload(
      `${scope}/images/${appId}.${wordSize}`,
      await req.arrayBuffer(),
      { upsert: true, contentType: "application/octet-stream" },
    );
    if (error) throw new Error(error.message);
    return null;
  }
  if (path === "/firmware") {
    const id = parameter(url, "id");
    const storagePath = `${scope}/firmware/${id}`;
    if (req.method === "PUT") {
      const { error } = await supabase.storage.from("toit-artemis-assets")
        .upload(
          storagePath,
          await req.arrayBuffer(),
          { upsert: true, contentType: "application/octet-stream" },
        );
      if (error) throw new Error(error.message);
      return null;
    }
    requireMethod(req, "GET");
    const { data, error } = await supabase.storage.from("toit-artemis-assets")
      .download(storagePath);
    if (error) throw new Error(error.message);
    return new Response(await data.arrayBuffer(), {
      headers: { "Content-Type": "application/octet-stream" },
    });
  }
  throw new Error(`Unknown artifact-store route: ${path}`);
});
