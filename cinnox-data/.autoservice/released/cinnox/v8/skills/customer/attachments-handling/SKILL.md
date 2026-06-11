---
name: attachments-handling
description: 'When customer attaches files (image / .har / log), read them via the
  Read tool and incorporate findings into the response.

  '
applicable_roles:
- customer
safety_class: soft
editable_by: tenant_admin
depends_on: []
last_updated: '2026-05-21'
version: 1
source: phase-e2 migration from plugins/cinnox/flow_chunks/cinnox-flow-attachments.md
channels:
- text
---


# Flow: File Attachments — reading uploaded files



When the customer's message arrives with an `<attachments>` block,

it appears before the "Customer message:" line in the user turn:



```

<attachments>

  <file name="example.har" path="/abs/sandbox/path/cinnox/uploads/conv_abc/uuid.har" mime="application/json"/>

  <file name="screenshot.png" path="/abs/sandbox/path/cinnox/uploads/conv_abc/uuid.png" mime="image/png"/>

</attachments>



Customer message: 这是我导出的 har 文件，帮我看一下！

```



## How to handle `<attachments>`



1. **Use the `Read` tool on each `path=` attribute** to inspect the

   file before composing your reply. The `path=` is an absolute

   sandbox path the customer cannot see — refer to the file by its

   `name=` in your reply, never by its `path=`.



2. **For `.har` files** (mime `application/json`, or `text/plain`

   for some browsers'/tools' dumps): The HAR is a browser network

   capture. Read the `entries[]` array; focus on failed responses

   (status 4xx/5xx) and slow requests (time > 3 s). Summarize the

   top finding in plain language for the customer, then include the

   technical detail in your recap before handing off (see

   `cinnox-flow-har-export`).



3. **For images** (mime `image/*`): Vision is NOT currently enabled.

   `Read` returns a description when the model supports it — until

   then, acknowledge the file by name and ask the customer to

   describe the issue in text if you cannot infer it from the

   filename or context. Do NOT pretend you can see the image.



4. **Always**: after reading, acknowledge receipt by filename ("我看了您发来的 `example.har`

   / I've reviewed your `example.har`"), then continue the .har export

   flow's recap and handoff (`cinnox-flow-har-export`).



> **Note:** The `<attachments>` block only appears when the customer

> actually used the upload button. If the block is absent, the customer

> has not uploaded a file — do not ask them to "wait while I read the

> attachment."


AUDIT marker.
