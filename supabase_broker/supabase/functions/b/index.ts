// Copyright (C) 2023 Toitware ApS. All rights reserved.

import { serve } from "std/server";
import { createClient } from "@supabase/supabase-js";

const STATUS_IM_A_TEAPOT = 418;

const COMMAND_UPLOAD_ = 1;
const COMMAND_DOWNLOAD_ = 2;
const COMMAND_UPDATE_GOAL_ = 3;
const COMMAND_GET_DEVICES_ = 4;
const COMMAND_NOTIFY_BROKER_CREATED_ = 5;
const COMMAND_GET_EVENTS_ = 6;

const COMMAND_GET_GOAL_ = 10;
const COMMAND_REPORT_STATE_ = 11;
const COMMAND_REPORT_EVENT_ = 12;

const COMMAND_POD_REGISTRY_DESCRIPTION_UPSERT_ = 100;
const COMMAND_POD_REGISTRY_ADD_ = 101;
const COMMAND_POD_REGISTRY_TAG_SET_ = 102;
const COMMAND_POD_REGISTRY_TAG_REMOVE_ = 103;
const COMMAND_POD_REGISTRY_DESCRIPTIONS_ = 104;
const COMMAND_POD_REGISTRY_DESCRIPTIONS_BY_IDS_ = 105;
const COMMAND_POD_REGISTRY_DESCRIPTIONS_BY_NAMES_ = 106;
const COMMAND_POD_REGISTRY_PODS_ = 107;
const COMMAND_POD_REGISTRY_PODS_BY_IDS_ = 108;
const COMMAND_POD_REGISTRY_POD_IDS_BY_REFERENCE_ = 109;

class BinaryResponse {
  bytes: Blob;
  totalSize: number;

  constructor(bytes: Blob, totalSize: number) {
    this.bytes = bytes;
    this.totalSize = totalSize;
  }
}

function createSupabaseClient(req: Request) {
  // Create a Supabase client with the Auth context of the logged in user.
  let authorization = req.headers.get("Authorization");
  if (!authorization) {
    console.log("Needing to add anon key to request");
    authorization = "Bearer " + Deno.env.get("SUPABASE_ANON_KEY");
  }
  return createClient(
    // Supabase API URL - env var exported by default.
    Deno.env.get("SUPABASE_URL") ?? "",
    // Supabase API ANON KEY - env var exported by default.
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    // Create client with Auth context of the user that called the function.
    // This way your row-level-security (RLS) policies are applied.
    {
      global: {
        headers: { Authorization: authorization },
      },
    },
  );
}

function extractUploadData(buffer: ArrayBuffer) {
  const view = new DataView(buffer);
  for (let i = 0; i < buffer.byteLength; i++) {
    if (view.getUint8(i) == 0) {
      return {
        path: new TextDecoder().decode(buffer.slice(0, i)),
        data: buffer.slice(i + 1),
      };
    }
  }
  throw new Error("invalid upload data");
}

function splitSupabaseStorage(path: string) {
  const start = path[0] == "/" ? 1 : 0;
  const slashPos = path.indexOf("/", start);
  if (slashPos == -1) {
    throw new Error("invalid path");
  }
  return {
    bucket: path.slice(start, slashPos),
    path: path.slice(slashPos + 1),
  };
}

async function handleRequest(req: Request) {
  const buffer = await req.arrayBuffer();
  const view = new DataView(buffer);
  const command = view.getUint8(0);
  const encoded = buffer.slice(1);

  console.log("handling command", command);
  const params = (command == COMMAND_UPLOAD_)
    ? extractUploadData(encoded)
    : JSON.parse(new TextDecoder().decode(encoded));

  const supabaseClient = createSupabaseClient(req);
  switch (command) {
    case COMMAND_UPLOAD_: {
      const { bucket, path } = splitSupabaseStorage(params.path);
      const { error } = await supabaseClient.storage
        .from(bucket)
        .upload(path, params["data"], { upsert: true });
      return { error };
    }
    case COMMAND_DOWNLOAD_: {
      const usePublic = params["public"] === true;
      const offset = params["offset"] ?? 0;
      const { bucket, path } = splitSupabaseStorage(params.path);
      console.log("downloading", bucket, path, params, usePublic);
      if (usePublic) {
        // Download it from the public URL.
        const headers = (offset != 0) ? [{ Range: `bytes=${offset}-` }] : {};
        const { data: { publicUrl } } = supabaseClient.storage.from(bucket)
          .getPublicUrl(path);
        console.log("Public download", publicUrl);
        return fetch(publicUrl, { headers });
      }
      if (offset != 0) {
        throw new Error("offset not supported for private downloads");
      }
      const { data, error } = await supabaseClient.storage.from(bucket)
        .download(path);
      if (error) {
        throw new Error(error.message);
      }
      return { data: new BinaryResponse(data, data.size), error: null };
    }
    case COMMAND_UPDATE_GOAL_: {
      const { error } = await supabaseClient.rpc(
        "toit_artemis.set_goal",
        params,
      );
      return { error };
    }
    case COMMAND_GET_DEVICES_: {
      return supabaseClient.rpc("toit_artemis.get_devices", params);
    }
    case COMMAND_NOTIFY_BROKER_CREATED_: {
      const { error } = await supabaseClient.rpc(
        "toit_artemis.new_provisioned",
        params,
      );
      return { error };
    }
    case COMMAND_GET_EVENTS_: {
      return supabaseClient.rpc("toit_artemis.get_events", params);
    }

    case COMMAND_GET_GOAL_: {
      return supabaseClient.rpc("toit_artemis.get_goal", params);
    }
    case COMMAND_REPORT_STATE_: {
      const { error } = await supabaseClient.rpc(
        "toit_artemis.update_state",
        params,
      );
      return { error };
    }
    case COMMAND_REPORT_EVENT_: {
      const { error } = await supabaseClient.rpc(
        "toit_artemis.report_event",
        params,
      );
      return { error };
    }

    case COMMAND_POD_REGISTRY_DESCRIPTION_UPSERT_:
      return supabaseClient.rpc("toit_artemis.upsert_pod_description", params);
    case COMMAND_POD_REGISTRY_ADD_: {
      const { error } = await supabaseClient.rpc(
        "toit_artemis.insert_pod",
        params,
      );
      return { error };
    }
    case COMMAND_POD_REGISTRY_TAG_SET_: {
      const { error } = await supabaseClient.rpc(
        "toit_artemis.set_pod_tag",
        params,
      );
      return { error };
    }
    case COMMAND_POD_REGISTRY_TAG_REMOVE_: {
      const { error } = await supabaseClient.rpc(
        "toit_artemis.delete_pod_tag",
        params,
      );
      return { error };
    }
    case COMMAND_POD_REGISTRY_DESCRIPTIONS_:
      return supabaseClient.rpc("toit_artemis.get_pod_descriptions", params);
    case COMMAND_POD_REGISTRY_DESCRIPTIONS_BY_IDS_:
      return supabaseClient.rpc(
        "toit_artemis.get_pod_descriptions_by_ids",
        params,
      );
    case COMMAND_POD_REGISTRY_DESCRIPTIONS_BY_NAMES_:
      return supabaseClient.rpc(
        "toit_artemis.get_pod_descriptions_by_names",
        params,
      );
    case COMMAND_POD_REGISTRY_PODS_:
      return supabaseClient.rpc("toit_artemis.get_pods", params);
    case COMMAND_POD_REGISTRY_PODS_BY_IDS_:
      return supabaseClient.rpc("toit_artemis.get_pods_by_ids", params);
    case COMMAND_POD_REGISTRY_POD_IDS_BY_REFERENCE_:
      return supabaseClient.rpc("toit_artemis.get_pods_by_reference", params);

    default:
      throw new Error("unknown command " + command);
  }
}

serve(async (req: Request) => {
  try {
    const result = await handleRequest(req);
    if (result instanceof Response) {
      // This shortcuts the downloading of a public file and uses the headers
      // from the 'fetch'.
      return result;
    }
    let { data, error } = result;
    if (error) {
      throw new Error(error.message);
    }
    if (data instanceof BinaryResponse) {
      const isPartial = data.bytes.size != data.totalSize;
      const headers = {
        "Content-Type": "application/octet-stream",
        "Content-Length": data.bytes.size.toString(),
        ...(isPartial && {
          "Accept-Ranges": "bytes",
          "Content-Range": `bytes 0-${data.bytes.size - 1}/${data.totalSize}`,
        }),
      };
      return new Response(data.bytes, {
        headers: headers,
        status: isPartial ? 206 : 200,
      });
    }
    if (data === undefined) {
      // This simplifies the response handling in the client.
      // TODO(florian): also allow empty responses.
      data = null;
    }
    return new Response(JSON.stringify(data), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    return new Response(JSON.stringify(error.message), {
      headers: { "Content-Type": "application/json" },
      status: STATUS_IM_A_TEAPOT,
    });
  }
});

// To invoke:
// curl -i --location --request POST 'http://localhost:54321/functions/v1/b' \
//   --header 'Authorization: Bearer ...' \
//   --header 'Content-Type: application/json' \
//   --data '{"name":"Functions"}'
