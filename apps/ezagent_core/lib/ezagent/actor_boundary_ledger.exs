# Frozen SITE fingerprints for the actor-boundary gate — DATA ONLY.
# Loaded at compile time by `Ezagent.ActorBoundaryLedger` (a `.exs` data file,
# not a compiled module, so it stays out of the oversized-module `.ex` count).
# Each entry is `%{path, target, sha, note}` where `sha` is SHA-256 of the
# trimmed offending source line. Regenerate via the enumerator (see the gate).
%{
  # §4.4 reach-in census — migrates onto the §2.2 read surface (C1-C5; get_slice ratchet->C7).
  forward_ratchet: [
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior/sandbox.ex",
      target: "Ezagent.KindRegistry",
      sha: "e992bd6b4725f484610c8ec20d8d14113eae4429babea69fc5c6ffa6fb18c8d5",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior/sandbox.ex",
      target: "Ezagent.SnapshotStore",
      sha: "c31c08b84d6bbf743380b518a71e7949258ad085a117cce09421415709dd4546",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior/sandbox.ex",
      target: "Kind.get_slice",
      sha: "6995f24042e321a84fc7d362d44fa51206ad1f983f1e1c1f2d69aba069ee2b84",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior/terminable.ex",
      target: "Ezagent.KindRegistry",
      sha: "e992bd6b4725f484610c8ec20d8d14113eae4429babea69fc5c6ffa6fb18c8d5",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "Ezagent.Kind.BehaviorSet",
      sha: "3240666ab0ea845326d8c26b3af2e2f875d78c305fbabf00907e0f9aa3364ee0",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "Ezagent.Kind.BehaviorSet",
      sha: "e0959391bfa73b1dc9f151b35a92c5fd2094bdd1da8f8bbcda2ba8f040b56c9d",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "Ezagent.KindRegistry",
      sha: "3682c2563fb9dcdc44357d99068fbc3d4f6698baabde172b4b94efb37b035e52",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "Ezagent.KindRegistry",
      sha: "6ca359df5da0b3e0ca7a988d3b29f1c8a20d4260db22358ed4bb72f41b0be53d",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "GenServer.call(:ezagent_*)",
      sha: "0e54a30dcf36c53ed2d9468c2c028f63570abd87bf0f1efde35686cff278f072",
      note: "raw :ezagent_* GenServer shape → dispatch/read (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "GenServer.call(:ezagent_*)",
      sha: "0e54a30dcf36c53ed2d9468c2c028f63570abd87bf0f1efde35686cff278f072",
      note: "raw :ezagent_* GenServer shape → dispatch/read (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "GenServer.call(:ezagent_*)",
      sha: "0e54a30dcf36c53ed2d9468c2c028f63570abd87bf0f1efde35686cff278f072",
      note: "raw :ezagent_* GenServer shape → dispatch/read (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "GenServer.call(:ezagent_*)",
      sha: "dcd067eed429ea88c2d459c6df11298cd8d768427a4da94519766e253e016165",
      note: "raw :ezagent_* GenServer shape → dispatch/read (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "ReadyGate.status",
      sha: "8c05836c1b96135ccb6743eb16010565eda730f83a7b2620d875bb248adb4b50",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap/authorize.ex",
      target: "Cap.Authority.current_process_generation",
      sha: "4159b8d32d9d114b756f0ee2b545d7c03bd9e76a0812c604c70edfd0af4353d5",
      note: "process-generation seed (a) → deleted at C4"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap/target_artifact_validator.ex",
      target: "Ezagent.KindRegistry",
      sha: "af1d73b8895ee8e0412eb7071a036050a858705f6b80c3c8b27d2097426d4c9b",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cap/target_artifact_validator.ex",
      target: "GenServer.call(:ezagent_*)",
      sha: "28ded14ab5cc75498ef8d3c4cd214870d50ef6811ad5dc370651f6473efdb0a1",
      note: "raw :ezagent_* GenServer shape → dispatch/read (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/credential/grant_row.ex",
      target: "Ezagent.SnapshotStore",
      sha: "660138bda4d9e2cc6bf3fc26e37381b64cda68410abaaf0e99897bde683fcf40",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/credential/resolver.ex",
      target: "Ezagent.SnapshotStore",
      sha: "5dc803f181280ecc9e152f58c96fd3321d30b12e917834ac3fa209652c4f24b5",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/credential/resolver.ex",
      target: "Ezagent.SnapshotStore",
      sha: "c41049af5ab11d8ccb6a17f258f83941e2a40cd126a90770bdc1bc027f660b32",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/home/migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "026ce287ebfdcc17f536dd06103801920163dd26734301d1361190b03bc3ce59",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/home/migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/home/migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "e48f9b87f8ccc79a44436aed2e1d428949e6580ce201353c62ae2a93375d9b59",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle_case.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle_case.ex",
      target: "Ezagent.KindRegistry",
      sha: "47da3456be371efbc286f62ac6784982fcb3ccea71becf603e88a9d88af06712",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle_case.ex",
      target: "Ezagent.KindRegistry",
      sha: "61bac585da2d0bcd9dafb447f1b2b06ff1a5329298e5c5b9c72486647faeb280",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle_case.ex",
      target: "Kind.get_raw_slice",
      sha: "d218c14a8c38590288c95fee15908fc244a7cf46497ceb003c7a368d39cefb85",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle_case.ex",
      target: "Kind.get_raw_slice",
      sha: "d218c14a8c38590288c95fee15908fc244a7cf46497ceb003c7a368d39cefb85",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle_case.ex",
      target: "ReadyGate.status",
      sha: "bc2782d9a156b832c76ff86a377119d1dccf48a8e55ad05e2c83593674b25747",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle_case.ex",
      target: "ReadyGate.status",
      sha: "f2b9b69858ee18c0be2623ca5c3005562c57fb74db35de58947074d91cfec9bf",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "649ea59346bc77601f32dfe66870e7f21655f34b67bd15f5133d955bc7b09abf",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "90314de9d4604d50f621e6af9ce513872c0527c217e22aed74156e92ba9675f1",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a1efcb105ca1a58f57a701fe3259fc52e9f8f06efdf9231b9b16188345624e0e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a1efcb105ca1a58f57a701fe3259fc52e9f8f06efdf9231b9b16188345624e0e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
      target: "Ezagent.Kind.Snapshot",
      sha: "4247f9f0eb2d5e552782e7de1ec801400c2a7d4a75e7d68d8b65bc8ba03e9f8c",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/stress_metrics.ex",
      target: "Ezagent.KindRegistry",
      sha: "08916c8e878652e07a38c5cabacb5dcc457a7893ee4655dc31d04eddf70f12ca",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/stress_metrics.ex",
      target: "Ezagent.KindRegistry",
      sha: "9c34001ce38e6b897dfec5a6b31abbe2c343c56e842bdd6fead7084fffcd3680",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/stress_metrics.ex",
      target: "Ezagent.KindRegistry",
      sha: "ea414c8494a131655a84daf5a8e6801bef4e5f8dcde7e1fa740c0ef14a8b8ac9",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent_core/application.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent_core/application.ex",
      target: "Ezagent.KindRegistry",
      sha: "6e412b60d595660e520ecfbae90f5d1ab88c2d22245cfdf8d769fc570a02150f",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent_core/application.ex",
      target: "Ezagent.Snapshot.Writer",
      sha: "9d9538fb4bc3a8539516f1b9efb26dfb405189feaa0d377b8701f9a485ccc70e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent_core/application.ex",
      target: "Ezagent.Snapshot.Writer",
      sha: "9d9538fb4bc3a8539516f1b9efb26dfb405189feaa0d377b8701f9a485ccc70e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent_core/data_case.ex",
      target: "Ezagent.KindRegistry",
      sha: "ab6166200b89607028191d2d23972219a140776dde0c173ce5dc4178fd1472ed",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent_core/data_case.ex",
      target: "GenServer.call(:ezagent_*)",
      sha: "4d02b65ffd4b179062a42b652e97d7adfb7e3134eb55dbd5e3f89866aff3fbde",
      note: "raw :ezagent_* GenServer shape → dispatch/read (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent_core/ets_owner.ex",
      target: "Ezagent.Idempotency",
      sha: "4d91a26364e314d611d10533e83bef3477c048be339a9deb890ea349497a2524",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent_core/ets_owner.ex",
      target: "Ezagent.PendingDelivery",
      sha: "ba7548bede71ad4d54b03fa1b270e4cf7c6c25ce09c17a7a5620214f84e38c97",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.clear.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "2d52d412a1d04fc2e3bd2202e3877bde1889c64ef38c5c8a70914f9b19e0c80d",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.clear.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "929454485e266b8cbcd818ffde8fc22379b77f8ab47d2cf581fdbdbbdcd1c708",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.dump.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "1567ebd2fdeb22340fea9aadf7bea91cf7f54d91d2e18439b8c772074fbac2b5",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.dump.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "2d52d412a1d04fc2e3bd2202e3877bde1889c64ef38c5c8a70914f9b19e0c80d",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.list.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "b160b52495fdfcfb980d34d635c906e3a173366011ed95479257ae9dbee1b586",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex",
      target: "Ezagent.KindRegistry",
      sha: "c32df9ff4e28f39356a09ae3468077c0fdd1d73b1693b2d58ce957f1311b02e6",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex",
      target: "ReadyGate.status",
      sha: "a12e71036ddb2f3fd617b79ca8f8007b1b7ca55855c6cf024d367d377cf1c6e7",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/credential_status.ex",
      target: "Ezagent.SnapshotStore",
      sha: "c31c08b84d6bbf743380b518a71e7949258ad085a117cce09421415709dd4546",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/credential_status.ex",
      target: "Kind.get_slice",
      sha: "e9a9b1c24e375aaf5ae12d5eb55cf82cf01112736d6b7952ed4419149fe0523f",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/host_login_adopt.ex",
      target: "Ezagent.SnapshotStore",
      sha: "fda2877d535ddbe515247717083d10138bf3d09e482420d3349cbd51758aebfd",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "8bb14788dad6bb970b25a9967700872c39848bc2dfd4a88a0a0d0fe492f12267",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "95dae710d34cd8145037f54cbc5eab763e8d26d5ec14784f933d75bcf6e09bce",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a1efcb105ca1a58f57a701fe3259fc52e9f8f06efdf9231b9b16188345624e0e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "f7b14e9bf2dd1a65c1da64444a7801b5e909e4ba12484e61f37e78b31dfd1849",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "fd7485ad8e9530f470e2acf2cb8984420a7602a618e94124379f80a6690c0b06",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      target: "Ezagent.SnapshotStore",
      sha: "c31c08b84d6bbf743380b518a71e7949258ad085a117cce09421415709dd4546",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/retirement_sweeper.ex",
      target: "Ezagent.KindRegistry",
      sha: "af1d73b8895ee8e0412eb7071a036050a858705f6b80c3c8b27d2097426d4c9b",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.Kind.ReadyTransition",
      sha: "5c0c4635529614d3aa0a5f2a622ee3684b99e08e96321a098873705e0850273f",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.Kind.ReadyTransition",
      sha: "a6164dbf11f04dfe289608f93f1b30b86c2f2eb9686f2816ecab7cde17d1fc4f",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.Kind.ReadyTransition",
      sha: "a6164dbf11f04dfe289608f93f1b30b86c2f2eb9686f2816ecab7cde17d1fc4f",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.Kind.ReadyTransition",
      sha: "a6164dbf11f04dfe289608f93f1b30b86c2f2eb9686f2816ecab7cde17d1fc4f",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.Kind.ReadyTransition",
      sha: "bd9c2bb0bd53ad0aa4b54114d8dd3d07aa9c48b3ae4438d33f79d30ea31697cc",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.Kind.ReadyTransition",
      sha: "e993ab3f3fa5a36621040523f96f3c7ff1d1035b8fa5d578b2fb176a8bf7717e",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.KindRegistry",
      sha: "6633a680e7cd5c9b9477d8f8aa0f7880e778242ecca758cd0313e80a9bdcd400",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.KindRegistry",
      sha: "c0e413a25b0daa95c40722523009af7a0c74473ee56d296d00d68f1767ebbaf2",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "Ezagent.PendingDelivery",
      sha: "6a84fa6fda3cf0057bf48f67a2843b0f2e76707a0cda008474a89ed1c77ce182",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "ReadyGate.put",
      sha: "16b205786ebfc7957df4ac632901c4513a63f7069100dc1398d0276d51deddae",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "ReadyGate.status",
      sha: "4517a14c816c228258123430452140841e88ec945a0f15bfed2a7ae559d6f755",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      target: "ReadyGate.status",
      sha: "afbeeb7d49bba47d5f15e51ac3bd57e4523f4ed3232c2d47aacf0b5e9c3d696f",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/agent_flavor_resolver.ex",
      target: "Ezagent.SnapshotStore",
      sha: "6f0efa841ae7b75d169ef72711f15f2f98cf8bba6c084cbf3474d9953304ed81",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex",
      target: "Kind.get_slice",
      sha: "0f8d5de18c5fc3f6559c6dea1df2cb7e2ab34dadc56f782a2e9e23ed7c114cf7",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/domain/agent.ex",
      target: "Ezagent.KindRegistry",
      sha: "c0e413a25b0daa95c40722523009af7a0c74473ee56d296d00d68f1767ebbaf2",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "007498fd3e0fb1d62958eed18b328851e8f250ea5085d4d11f11d04933cf9b82",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex",
      target: "Kind.get_slice",
      sha: "74790cbde6881354183b1561071e45076051a9b3be41a123af27c15712498828",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex",
      target: "Ezagent.KindRegistry",
      sha: "9e922d652666e94a5c2821c91e407f2dd8a9141d87e728374b026a38c5f59ccd",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "9973bd17d98a4a40ff8fabf8ef6fcc91352cd00cd084f6e01ae05d81d0a5d176",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "fece7ad67f512dca90895a843b51543445a6081ced6d3d8cdb8bae770e661e91",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge.ex",
      target: "Ezagent.SnapshotStore",
      sha: "c31c08b84d6bbf743380b518a71e7949258ad085a117cce09421415709dd4546",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path:
        "apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/per_binding_supervisor.ex",
      target: "Ezagent.Kind.Server",
      sha: "53d7545a958c5b711c728308372f39ee33b738fd84c080b29bffec48eb82f45a",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path:
        "apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/per_binding_supervisor.ex",
      target: "Ezagent.Kind.Server",
      sha: "ade3de36d4e024452d0e58e4e0896e65a19a4d50834b2ae39d22b8a8cf70e72d",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_git/lib/ezagent/domain_git/task_access_supervisor.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_git/lib/ezagent/domain_git/task_access_supervisor.ex",
      target: "Ezagent.KindRegistry",
      sha: "d7be9688fdeb689151879e0f458c60d95248422758e069b61202be0a47703140",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex",
      target: "Kind.get_slice",
      sha: "a48f1cb3c99de0a4acc94b3fa05c39eeb259d4af679a5b6b6088a7109b27e97c",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex",
      target: "Kind.get_slice",
      sha: "0f8d5de18c5fc3f6559c6dea1df2cb7e2ab34dadc56f782a2e9e23ed7c114cf7",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/behavior/user_default_credential_source.ex",
      target: "Ezagent.SnapshotStore",
      sha: "139207f444c1d6a0d374534ef1a8ecda6d995392a30e94b3b9da51636e1e289a",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_shared_credential_source.ex",
      target: "Ezagent.SnapshotStore",
      sha: "139207f444c1d6a0d374534ef1a8ecda6d995392a30e94b3b9da51636e1e289a",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.KindRegistry",
      sha: "51b3fc35ed6232b9d66febd5c9807c1599fb8ea1b15901ab6c6af4951677743e",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.KindRegistry",
      sha: "8cecb884167fcb6fe269d6e9b38267929519ce94d307fb6080e878e5e54bee70",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.SnapshotStore",
      sha: "3e6fcf45ef18fa1de19b71991bb9a5ff12d24cd9c707d4aa7b0585cf71dc0491",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.SnapshotStore",
      sha: "532cd379a99ad772a2fcc0d15b8967d47f338a32056ae7344d785985eff968d4",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.SnapshotStore",
      sha: "6802115044ba88a03b103310309c568d890d0c27b5a0b27a8a23ee67d0289b1c",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.SnapshotStore",
      sha: "6802115044ba88a03b103310309c568d890d0c27b5a0b27a8a23ee67d0289b1c",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.SnapshotStore",
      sha: "a690bdf90814f0fbb3346866350976c2fb48489ff13b7e4991c00fe6060b4244",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Kind.get_slice",
      sha: "b1c74ccfac7c4487ee715279f7fc0d42b704debe94764af0aa314bd407360d69",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "ReadyGate.await",
      sha: "2b334508065e45667305662d0697396175edef3d25e0ddc0572ee91862c86b49",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "90314de9d4604d50f621e6af9ce513872c0527c217e22aed74156e92ba9675f1",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a1efcb105ca1a58f57a701fe3259fc52e9f8f06efdf9231b9b16188345624e0e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a1efcb105ca1a58f57a701fe3259fc52e9f8f06efdf9231b9b16188345624e0e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "cd3ab850bea1a46baa29d3646d30d25166923870f533a82d06f2fe05a552d83a",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "cd3ab850bea1a46baa29d3646d30d25166923870f533a82d06f2fe05a552d83a",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
      target: "Ezagent.Kind.Snapshot",
      sha: "4247f9f0eb2d5e552782e7de1ec801400c2a7d4a75e7d68d8b65bc8ba03e9f8c",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/membership_convergence.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/offboarding/reaper.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/offboarding/reaper.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "7aca458d29d6fa20557708e4611f1bc6743f6fce6d18476a0f7c489a87650ae2",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/offboarding/reaper.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/operator_reads.ex",
      target: "Ezagent.KindRegistry",
      sha: "a936ab8fdbae421a25c598f5732af20da0fe65a8389482f98699eace90662b87",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex",
      target: "ReadyGate.status",
      sha: "92765b9b0c18ef956977e1bc45ea64abc8d24b4d022a5633069b5fd15fc3c524",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/target_authority.ex",
      target: "Ezagent.KindRegistry",
      sha: "b75fca1808cf51e332ff55e67a5d12450773d7a1fb4cae7465878b99b928b71c",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/target_authority.ex",
      target: "Ezagent.KindRegistry",
      sha: "ba1fafde98168e24355912b18ba7cb3c702ad491a7b92c5d1ff1c4c99d581468",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/identity/target_authority.ex",
      target: "GenServer.call(:ezagent_*)",
      sha: "e9a02c3a7bc01168171f4f6f6a38f3ed3f0207958878f3089491e9bb5e3b68a0",
      note: "raw :ezagent_* GenServer shape → dispatch/read (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/users.ex",
      target: "Ezagent.KindRegistry",
      sha: "8fa324dc6bbdea3c1dfbb3698abd5fc10100723e5bfd2a515e677afbb7ab5249",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/behavior/session.ex",
      target: "Ezagent.KindRegistry",
      sha: "8cecb884167fcb6fe269d6e9b38267929519ce94d307fb6080e878e5e54bee70",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/behavior/session.ex",
      target: "Ezagent.KindRegistry",
      sha: "cfabeae7c6b688ee727970a4173ae2e6ae741544afa021e91e18c88b7ed9bd10",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add.ex",
      target: "Ezagent.KindRegistry",
      sha: "d5e92588fc0809d6a697f283719f8fe0b49d6fc855621731ba66094155d53aa2",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/behavior/template.ex",
      target: "Kind.get_slice",
      sha: "274532442b59e29ac41061578897b87759baec390f5240393381db99a609a1c2",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex",
      target: "Kind.get_raw_slice",
      sha: "3ae0e094c9b263e472acd2bdde0588b7c653e3e03b001da7c41c112846afebdc",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session.ex",
      target: "Ezagent.KindRegistry",
      sha: "d92b05c20cd55e5c247aab6ff03077ba5c1eee0546d46cbff835c2842b73c441",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session.ex",
      target: "Kind.get_slice",
      sha: "6496e43430eed4e3a477df5ab0f86bafb9373f7105f5a047cdfd27447163e7ea",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex",
      target: "Ezagent.KindRegistry",
      sha: "5da2c73d01496f99f9af5c03ff5259488f4f567e1a9134b4e505aa8cc60be608",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/health.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/health.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "839dc41f43870e30d49fa34a483b15c692291b5c64a69b2bc513363c02e38efb",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/health.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a57c7ded84a31cc7ca343f2e26e714a1f0a2202afd9c818a7d20ac2f6ebd609e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/health.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "f2b47209114e7270916146e0bef16dc94cdeff7d35e32d22c739befb461f65f3",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/health.ex",
      target: "Ezagent.KindRegistry",
      sha: "47da3456be371efbc286f62ac6784982fcb3ccea71becf603e88a9d88af06712",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/health.ex",
      target: "Ezagent.KindRegistry",
      sha: "db45bcff63b2cb440f4e104d7f6009f340c3e7127c1f3e336c44432f2eb933da",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex",
      target: "Ezagent.KindRegistry",
      sha: "d92b05c20cd55e5c247aab6ff03077ba5c1eee0546d46cbff835c2842b73c441",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex",
      target: "Ezagent.KindRegistry",
      sha: "d92b05c20cd55e5c247aab6ff03077ba5c1eee0546d46cbff835c2842b73c441",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex",
      target: "Kind.runtime_view",
      sha: "9b4997a0fad5a718485980648443a41c45cf345208e3b04028ff16b6932ef885",
      note: "runtime_view retires (§2.3) → resolve_action_subject/2 or read/3 (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/migration.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "00a3d89f28a748d9aa7c144e21ffc9036b895b7ff609477900ddc8edcc9a8914",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "3f2883428006b7639c556ebd59e4b0d301bafd28c876864adbb90c0c2ade2d6d",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a6cb7c9a855ea550b222febcf6c65ac7214846ce9298b9f9e67b5739db3cd73d",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex",
      target: "Ezagent.KindRegistry",
      sha: "50a6fdd7aa7e3922aebae6b3ac43fa5409ab033712b8e7f4458a8e4a3e89354a",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex",
      target: "Kind.get_slice",
      sha: "7c98469450773e9b448ed9bd91a12265c73dbc9662ea7201d7ae4b81e1226ca6",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "026ce287ebfdcc17f536dd06103801920163dd26734301d1361190b03bc3ce59",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "7270e102528b18117667a977f7bd952dd7d7e2d10e553bdbd29d6656f4ce7c06",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session/offboarding_adapter.ex",
      target: "Kind.get_slice",
      sha: "274532442b59e29ac41061578897b87759baec390f5240393381db99a609a1c2",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session/template_reads.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "27fe7c3babe487e6466c777c54829a01c0646f32a1def0a834c441d3113ab627",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session/template_reads.ex",
      target: "Ezagent.KindRegistry",
      sha: "1230bcd73ac8cb36bff83623e1704b6869ecea4a9ed8585a6b200f4735071ece",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session_config/admission.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session_config/readiness.ex",
      target: "Ezagent.KindRegistry",
      sha: "07cbd8fab4c32130211cd21ac6c78dd6a8fe42c31bbf267c8c82b5996e63fbf0",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/session_config/readiness.ex",
      target: "ReadyGate.status",
      sha: "07cbd8fab4c32130211cd21ac6c78dd6a8fe42c31bbf267c8c82b5996e63fbf0",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/board_provision.ex",
      target: "Kind.get_slice",
      sha: "dcdb42d632ace982edeb4e7de13e8d9ae45394e544711e6a6756765d42760f53",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/board_provision.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex",
      target: "Ezagent.Kind.BehaviorSet",
      sha: "6d4aadda7954ec24296e0c24979dc86e409f3a36a09f4ab946931b598c13d662",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex",
      target: "Ezagent.Kind.BehaviorSet",
      sha: "878b1336ee189d226cf7a69aaa27519dd04ed6f689ff49c8300abb9d060318c6",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex",
      target: "Ezagent.Kind.BehaviorSet",
      sha: "fbf8f5709aa44240ce5aefd6e538d2e7042cadced06cae62abd4e16bbfffe146",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex",
      target: "Ezagent.KindRegistry",
      sha: "bce79b3dbfc2e001096a2e3e9c0a45faafdf11803ba012172e364fb176e3f3b2",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex",
      target: "Kind.runtime_view",
      sha: "c387091dbc25db84a1591b3e86110f0aaef55b1719639cab2c47f246a65c9c7a",
      note: "runtime_view retires (§2.3) → resolve_action_subject/2 or read/3 (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/agent_module_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "361bf548c2fa6af1e20460134ab4e975d0a372ca12942ca25ad5e4ac07d814ac",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/agent_module_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "672d081e534d70b8a0dfb81e1004c59644d222a115b0fa187f0c61c88e032e3a",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "9303becbc4d8af48fd93ffcedc73e23260f366e1863104870c65df7a6c8bfcb7",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/presence_fanout.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex",
      target: "Ezagent.KindRegistry",
      sha: "47da3456be371efbc286f62ac6784982fcb3ccea71becf603e88a9d88af06712",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex",
      target: "Ezagent.KindRegistry",
      sha: "a02b825e163b903e4b76a4b973b0e827a37abd6c9ef7db5dc3ee27e9fd0a0c0d",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex",
      target: "Kind.get_raw_slice",
      sha: "d71406cf25d63dd743bf4ec0cee1deaf53e99767ce3d08234fb65088cea27ffd",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/listing.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "00a3d89f28a748d9aa7c144e21ffc9036b895b7ff609477900ddc8edcc9a8914",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/listing.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "1567ebd2fdeb22340fea9aadf7bea91cf7f54d91d2e18439b8c772074fbac2b5",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/listing.ex",
      target: "Ezagent.KindRegistry",
      sha: "47da3456be371efbc286f62ac6784982fcb3ccea71becf603e88a9d88af06712",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/listing.ex",
      target: "Ezagent.KindRegistry",
      sha: "54bf33450c5633a853afdf63a397afd853bc462124df0257b39e6b8e12b435d3",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/listing.ex",
      target: "Ezagent.KindRegistry",
      sha: "a02b825e163b903e4b76a4b973b0e827a37abd6c9ef7db5dc3ee27e9fd0a0c0d",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "fece7ad67f512dca90895a843b51543445a6081ced6d3d8cdb8bae770e661e91",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_resolver.ex",
      target: "Ezagent.KindRegistry",
      sha: "47da3456be371efbc286f62ac6784982fcb3ccea71becf603e88a9d88af06712",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_resolver.ex",
      target: "Ezagent.KindRegistry",
      sha: "54bf33450c5633a853afdf63a397afd853bc462124df0257b39e6b8e12b435d3",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/uri_query_resolvers.ex",
      target: "Ezagent.SnapshotStore",
      sha: "6f0efa841ae7b75d169ef72711f15f2f98cf8bba6c084cbf3474d9953304ed81",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/uri_query_resolvers.ex",
      target: "Kind.get_slice",
      sha: "b8e8b9a424c6314f332daf49182a536ed7bc12377ab15fa6870432b0eba05ee5",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/gc.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/gc.ex",
      target: "Ezagent.KindRegistry",
      sha: "0ce311c4c20a4a1dbf6c3cfcee13939fb78dab9f4ec96cd634d241007b61ffdd",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/gc.ex",
      target: "Kind.get_slice",
      sha: "80a32dcd1ec3311b17996b522c75435856c0acaa5a45804e2c08c711e82293aa",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex",
      target: "Ezagent.Kind.StateRebuilder",
      sha: "4cc795a3cc098952d00760b488379979b685f84f3d7dc01d1caf9123dca1f844",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex",
      target: "Kind.get_slice",
      sha: "da83c746a701ae5d8e9714c7dfcfe9cd37638980363bceca981d62bd52492ee2",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_ui/lib/ezagent_domain_ui/auto_derive.ex",
      target: "Ezagent.KindRegistry",
      sha: "8b568d2d67cae73c759aa6c9486dbf2fb1a542f0c817dc0fd5d105d80d07d9c2",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_ui/lib/ezagent_domain_ui/auto_derive.ex",
      target: "Ezagent.KindRegistry",
      sha: "8cecb884167fcb6fe269d6e9b38267929519ce94d307fb6080e878e5e54bee70",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_ui/lib/ezagent_domain_ui/auto_derive.ex",
      target: "Ezagent.KindRegistry",
      sha: "e889c0adde1b4c0e06372ed06513463b15ca7724dbf9d9b9cd9cbfb0a2bb5fe4",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_ui/lib/ezagent_domain_ui/auto_derive.ex",
      target: "Kind.runtime_view",
      sha: "910bc99333697e505fd0c7b0309bdf995434e0646578f128ecd79204afb213a3",
      note: "runtime_view retires (§2.3) → resolve_action_subject/2 or read/3 (C3)"
    },
    %{
      path: "apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/terminal_view.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "007498fd3e0fb1d62958eed18b328851e8f250ea5085d4d11f11d04933cf9b82",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
      target: "Ezagent.KindRegistry",
      sha: "8cecb884167fcb6fe269d6e9b38267929519ce94d307fb6080e878e5e54bee70",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
      target: "Ezagent.KindRegistry",
      sha: "f13ce4b0ead16f71c811f19e366b7051b93d384d6dac8fbc7f55f9181ffe024d",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
      target: "ReadyGate.await",
      sha: "36e1d8a9a244b6527ee6131dbb312c783a3e85b0acf97e8a0faa622ac20c7f94",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
      target: "ReadyGate.status",
      sha: "5e31b1f18e6b6ffbae7621ba3d33e5b9bf05ebd3e3be636a894891d9a4aa6d12",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace/listing.ex",
      target: "Ezagent.KindRegistry",
      sha: "47da3456be371efbc286f62ac6784982fcb3ccea71becf603e88a9d88af06712",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace/listing.ex",
      target: "Ezagent.KindRegistry",
      sha: "54bf33450c5633a853afdf63a397afd853bc462124df0257b39e6b8e12b435d3",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace/provisioning.ex",
      target: "Ezagent.KindRegistry",
      sha: "6858c37da1f9aaceef23dac0d0295579f49fc149cbf1e2423d47dcae85a640c8",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace/provisioning.ex",
      target: "Ezagent.KindRegistry",
      sha: "942df3470805d3e512df074607c5f002318aebc8b8ba0cd9f018779f54aaba38",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace/responsibility_assignments.ex",
      target: "Ezagent.KindRegistry",
      sha: "6858c37da1f9aaceef23dac0d0295579f49fc149cbf1e2423d47dcae85a640c8",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_workspace/lib/ezagent/workspace/responsibility_assignments.ex",
      target: "Ezagent.KindRegistry",
      sha: "6cf188ac1bf8b0b44c4dd0a6e840b7b89408cbf10064242eb85101feb74d6de0",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
      target: "Kind.runtime_view",
      sha: "9b4997a0fad5a718485980648443a41c45cf345208e3b04028ff16b6932ef885",
      note: "runtime_view retires (§2.3) → resolve_action_subject/2 or read/3 (C3)"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "00a3d89f28a748d9aa7c144e21ffc9036b895b7ff609477900ddc8edcc9a8914",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "1567ebd2fdeb22340fea9aadf7bea91cf7f54d91d2e18439b8c772074fbac2b5",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "4830bc4624264425506c52650b67954c380d0aac07b666bef2ad26af89f14cae",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "826ab172e29f4278872b16268f6b4d5dbc9e8a713774b973d16dda78ee70007c",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_codex/lib/ezagent/orchestrator/codex_orchestrator_seed.ex",
      target: "Kind.get_slice",
      sha: "53aed956c9f03afe4a603c31692360324ca2239b27e76d6d640a4dae3a3e27ea",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/bridge_adapter.ex",
      target: "Ezagent.SnapshotStore",
      sha: "c31c08b84d6bbf743380b518a71e7949258ad085a117cce09421415709dd4546",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "1948de8ee9600c7d9f9d77aaefa565a0dfb2fa9198c3f8acae46da6fde763080",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "7ce204061293af1264724c62211cac61ed66d041eec4dc66f62e5d83163b6430",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "8e09468e04e2297903ebdcdfdbc5791561d8ed6376cc07080975df7940701826",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "8ff0738a810fdecdf5f70b27154fefd56ea8bf86b30bb48f4e2960388fa678af",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a1efcb105ca1a58f57a701fe3259fc52e9f8f06efdf9231b9b16188345624e0e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "f842893c649c9c2db7e396890833d3d959e65d948261347179ab8b51ff00bda8",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Kind.Snapshot",
      sha: "4247f9f0eb2d5e552782e7de1ec801400c2a7d4a75e7d68d8b65bc8ba03e9f8c",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex",
      target: "Ezagent.SnapshotStore",
      sha: "1dcafae04f769e252ee25608cd20f0ed67069f71009ca5065af04c47680ca765",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex",
      target: "Kind.get_slice",
      sha: "c515e957b52bff5ece795f35149dfd18fde0d42fc46ce8a01bd187c767288246",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/credential_bridge.ex",
      target: "Ezagent.SnapshotStore",
      sha: "89c27fb8c26f5ad0a792cef83abed1d6b9ef58d21cf6cf72a3a9bb3ed915ccd4",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex",
      target: "Kind.get_slice",
      sha: "da83c746a701ae5d8e9714c7dfcfe9cd37638980363bceca981d62bd52492ee2",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex",
      target: "Kind.get_slice",
      sha: "da83c746a701ae5d8e9714c7dfcfe9cd37638980363bceca981d62bd52492ee2",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_delegation.ex",
      target: "Kind.get_slice",
      sha: "da83c746a701ae5d8e9714c7dfcfe9cd37638980363bceca981d62bd52492ee2",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/members.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/migrate.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "fece7ad67f512dca90895a843b51543445a6081ced6d3d8cdb8bae770e661e91",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex",
      target: "Kind.get_slice",
      sha: "7c469abaa097757c3873bf0fbafbe80f89c384fd23eb742331c4e8c181c4fbe2",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex",
      target: "Kind.get_slice",
      sha: "da83c746a701ae5d8e9714c7dfcfe9cd37638980363bceca981d62bd52492ee2",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban_render.ex",
      target: "Kind.get_slice",
      sha: "06bac6c1d48916feb9728201d767ea7ec398e21382e8ae6ede9be49886dea24e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex",
      target: "Kind.get_slice",
      sha: "f3a5a708bfc75f1aae0ad08de2f266288a1644d8879786ffade337aa110e1080",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    },
    %{
      path: "apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex",
      target: "Ezagent.Kind.StateRebuilder",
      sha: "b6a10a6442e37ab7e513e89f10ae8e43716a9eb2755e2e3207a11bbc3e45b102",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex",
      target: "Ezagent.KindRegistry",
      sha: "9d21c4c1fba4090bd0f00e8e443e460c2c17ba65975142681964d16b1cfae976",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex",
      target: "Ezagent.KindRegistry",
      sha: "b1526ccc57b3b6e0d76333805d14699bd77690edcdb734ee3c7afc22c7a26e42",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex",
      target: "Ezagent.SnapshotStore",
      sha: "383e09a1ce91b0b903eaa9840c71b70170650e3be31894120f16608d9d477208",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_web/lib/ezagent_web/live/home_live.ex",
      target: "Ezagent.KindRegistry",
      sha: "7934c105f5132fd6aff426577900e8254e8c9083946627d582500b3563dc275c",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_web/lib/ezagent_web/live/home_live.ex",
      target: "Ezagent.KindRegistry",
      sha: "de287787ac43a818c02d7e954756822769dec411bb65dc15a83590fc689f5c6f",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_web/lib/ezagent_web/live/home_live.ex",
      target: "Ezagent.SnapshotStore",
      sha: "53c1c84a2828c7820604bf1e21fe719859c7455d3f66f89c04e843a1caabb23d",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex",
      target: "Kind.get_slice",
      sha: "ed51052605487aefb84cb9732d12d2a48dff963db2897d1fb6f9edbb1b51542e",
      note: "get_slice reach-in → read/3 (ratchet→C7)"
    }
  ],
  # §4.2 fixed process-generation consumers that SURVIVE C4 (cap.ex, entity/token.ex).
  forward_fixed: [
    %{
      path: "apps/ezagent_core/lib/ezagent/cap.ex",
      target: "Cap.Authority.current_process_generation",
      sha: "6e623470e783f4e1d8db6b0f61f9f22e4e7f32f835c604f5d6a9de6d37f983eb",
      note: "permanent process-generation consumer (survives C4) — §4.2 fixed allowlist"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity/token.ex",
      target: "Cap.Authority.current_process_generation",
      sha: "b2c1d10b008894086ff62b21ff6ff7bdfabbb2b5aecd0c9f15f783177a3e07be",
      note: "permanent process-generation consumer (survives C4) — §4.2 fixed allowlist"
    }
  ],
  # §3.4 port worklist — mover-set upward refs (retired at C5).
  reverse_ratchet: [
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior.ex",
      target: "Ezagent.Capability",
      sha: "2c8991cab2ed7fed28041b1d2951c6d8a51db27294a4a80648dbedbdf2469f32",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior/introspection.ex",
      target: "Ezagent.CapabilityRegistry",
      sha: "8a67193ba0a8672245a3755d8f37367dd64f6c243151df4f64537f9b9b7e9dea",
      note: "§3.4 upward ref: Ezagent.CapabilityRegistry"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cmd.ex",
      target: "Ezagent.Capability",
      sha: "0d66c6f89e620d69569f6d025ee72f39c935ba2b45224eac575ce93ab09bf6e7",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/cmd.ex",
      target: "Ezagent.DispatchOrigin",
      sha: "fec578c34f032360fdb1da41b1b074754e9b39d0ce41b63dbc91e9ce4d1abd18",
      note: "§3.4 upward ref: Ezagent.DispatchOrigin"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "Ezagent.Persistence",
      sha: "a85a69cb92fb073b94db403bee942119b45c43169b98d871db2b8bcce30fcac7",
      note: "§3.4 upward ref: Ezagent.Persistence"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "Ezagent.Persistence.TransientRetry",
      sha: "81d2a56472251f1266ac2e13bf51528f28fe6029ecef3d317aff5748a9a44518",
      note: "§3.4 upward ref: Ezagent.Persistence.TransientRetry"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "50adb16d3b8b81cbbeef45c9fa374e0c58e24421a2defc2fccf52f31ce3cb678",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "6d32a5ec9a30a8f1182d81e26755d73e5cfbe994664dcbd6aa980a1e015082ce",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "6d32a5ec9a30a8f1182d81e26755d73e5cfbe994664dcbd6aa980a1e015082ce",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "886778badc0804e642b2df2bfd2327cec40888ea18b3699576892b75440e679d",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "8ec2e674be3a8ca700e7bad50de78146c0d3cf0ac9aee24369b751241fe1b16d",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "a169150ca734b25cd66f489dfa32fed5f7521f3ecd0d2b95669a3baad15b8031",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "b4f36f3859463903f6437eff1a232c6a180940ceee1c5c4a728e0091647a8341",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "b4f36f3859463903f6437eff1a232c6a180940ceee1c5c4a728e0091647a8341",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "b4f36f3859463903f6437eff1a232c6a180940ceee1c5c4a728e0091647a8341",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "cd5499927faafded831d06f33c1ba32a54444ce8d0eb31f8433db0bf7c0159cf",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "dba1d4d67eeb3d0e564c26b0d33a550df4fef5ce57e98e6ea30ee11c97f9a665",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
      target: "EzagentCore.Repo",
      sha: "e889ae08c82471e5db5028b06f1303d64c961d2099f010fa2c7bf047edf963ea",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Cap",
      sha: "bcd4738a093f45dce7f480afdb7ee63cf389601eff3c8225709695ca43219c87",
      note: "§3.4 upward ref: Ezagent.Cap"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "57e953c716afb89cc14c9c4e5c2945cdf042f00aa3f816b4a27ded21acd4e706",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "b221962e510750be966a7e289be941cf13870b089f3b59d12deb2b8630aa6f2f",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "b221962e510750be966a7e289be941cf13870b089f3b59d12deb2b8630aa6f2f",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "bb97846709e86453e96d6b6b82864e6e05581fe5bbadc6fc797ec2ba92ae6edb",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "c05cb6ea136a6f84dd0d5c27e41b0628f2fe86bc529bf50921f2fd4fb26d6dc6",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "d754b39f6bc8633947fda3bd923c47392dd3637979b4dee95a1a12419bfffece",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Cap.Verifier",
      sha: "a213c0832a21d37b52c493faf877529fa5a7e1e7ca086a83555a81530d29ed98",
      note: "§3.4 upward ref: Ezagent.Cap.Verifier"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.Capability",
      sha: "61f9ccae304668476f5eac77dd5709c0086321eb09c7127b8d60157c7ba4f26d",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.DLQ",
      sha: "d40dc8d3fb306e34f0eb75a391cc98dce557567c5be16fab8d301faf41b62ce1",
      note: "§3.4 upward ref: Ezagent.DLQ"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.DLQ",
      sha: "ddb075df7a5b51b90d7e3c7290a7acdc4651bfe0a0e6af5b5925508f6ffa8f6b",
      note: "§3.4 upward ref: Ezagent.DLQ"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.DispatchOrigin",
      sha: "7cbebf161234c98750f0aa73f1db17c00e99d137c66a48191386442a0313f601",
      note: "§3.4 upward ref: Ezagent.DispatchOrigin"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.DispatchOrigin",
      sha: "fec578c34f032360fdb1da41b1b074754e9b39d0ce41b63dbc91e9ce4d1abd18",
      note: "§3.4 upward ref: Ezagent.DispatchOrigin"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "Ezagent.WorkspaceOwnerGate",
      sha: "6d6c3002363a4b77586d8b1d3a78f130e58ee5dc0ced1f4ea380ca7d1991957e",
      note: "§3.4 upward ref: Ezagent.WorkspaceOwnerGate"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/invocation.ex",
      target: "EzagentCore.PubSub",
      sha: "776de3e60633c1e07826026cd1ccad6123821011d0d115fcc08c0f0f44033ece",
      note: "§3.4 upward ref: EzagentCore.PubSub"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Cap",
      sha: "eece826f7cdbe5930c32d4d6ecb5c3371fab3c2d741fb71624bf3fc3c2fc7e12",
      note: "§3.4 upward ref: Ezagent.Cap"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "0afd636fb7291f6f7cf00fad2cc20e09030ec552e0d0826bf503d3c41e7cc680",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "0fc0bc52a685b237af5b414ef472da9f907fdbc63d3c4fb7a31c9fb4a6a88735",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "1d78a9be2e9f8b2bca314c52a2a4fc56859a1279c31a4bd4cdd9540ec1494606",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "29344b81df36b4051143fd8f9079ddbd0f015fc0dd398c0f7d2d0521033efba7",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "8718dfe861e385b762aaeb5546bbe6ac6361a68aab84e6818515c9f60350a93c",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "a6664f105e75532523d42d6b11968aa7eaed29a4853a042389f2cdb1c2f51a4d",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "aefae22768263285840512144b3ecdda7c2058d2c1333cf036dd233aadbae962",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "c6f3efa58350d6896b02932eabbea9a209af0b5d324c37276bf02f6ae1b7b996",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "d4cb55893f65d609f3bf2a72a0a41c6525bc5439d6e421439f92cb24ad05ed15",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind.ex",
      target: "Ezagent.Capability",
      sha: "e9b6cc10c717d6d9f83a8afe7253d2c85e4b8624abfba5c2cc12388d75112f9b",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.ApiKeys",
      sha: "3046d845a834fd11933fca5cf440603bfcbd99b4432e528642eb04a54020e606",
      note: "§3.4 upward ref: Ezagent.ActionSet.ApiKeys"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.CcHeadlessAgent",
      sha: "a0ddbfad87653cde1fc181e1c4469f7a4cef175427cbfbc550bf5448a3c6b74f",
      note: "§3.4 upward ref: Ezagent.ActionSet.CcHeadlessAgent"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.ConfigEvolve",
      sha: "503ac384a93c971cd29a163c492404dc55dd1d4c2ab8838ff03e8f2be88042f3",
      note: "§3.4 upward ref: Ezagent.ActionSet.ConfigEvolve"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.ConfigEvolve",
      sha: "cfb140b459824d0d7d420b06c0c4769ccc9302aed95206e12e2245c5839076b3",
      note: "§3.4 upward ref: Ezagent.ActionSet.ConfigEvolve"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.CurlAgent",
      sha: "5a83e8d6f378b03ed139e113fcff0f9848424d754c672a8972605489a1b08711",
      note: "§3.4 upward ref: Ezagent.ActionSet.CurlAgent"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.ExternalMirror",
      sha: "3b2017dfe4961fc46d2be046706a75efdf678100a4aa2a724fdc136d9419d4e6",
      note: "§3.4 upward ref: Ezagent.ActionSet.ExternalMirror"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.ExternalMirror",
      sha: "6f92dbe6ffc7999a0a16c8ca620e8caa04b3184385aa97436cd184b85eaad31c",
      note: "§3.4 upward ref: Ezagent.ActionSet.ExternalMirror"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Identity",
      sha: "d6f982aedcc43af06d6383d30e826abfc773e9e7a619ac903179a4f991de6bdd",
      note: "§3.4 upward ref: Ezagent.ActionSet.Identity"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Publisher.SessionImpl",
      sha: "9f4ac0d8d2518d2358233f52f99058e1d31052a0d3a9ffc193af58bbe7b65ff1",
      note: "§3.4 upward ref: Ezagent.ActionSet.Publisher.SessionImpl"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Sandbox",
      sha: "241014350e4dcd8ef6ed15d455f0e3f6c84d5f6d4f0740380aa33ad25af5f07a",
      note: "§3.4 upward ref: Ezagent.ActionSet.Sandbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Session",
      sha: "00b7b0167f819f7c6f709e89196fb898d589ccaee9e54f8bc58ee61d2a18e3c8",
      note: "§3.4 upward ref: Ezagent.ActionSet.Session"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Session",
      sha: "1e60eab48739d33a20dc5f8b88d56735999c39538de9f5b9c69d072795b8b53c",
      note: "§3.4 upward ref: Ezagent.ActionSet.Session"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Surface",
      sha: "8b07654223afd6811c76ba6aefa9085eea8ed3f866a00e56765fe6bd3a1469f3",
      note: "§3.4 upward ref: Ezagent.ActionSet.Surface"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Turn",
      sha: "81f519b27b69f0745ba2088de64c9f2f3e9225e5f40c400f6b5310fdb9a60509",
      note: "§3.4 upward ref: Ezagent.ActionSet.Turn"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Turn",
      sha: "89df46823562e208dc18e5e193e8feb8154b0469f1cf9d002b92588e316ecea1",
      note: "§3.4 upward ref: Ezagent.ActionSet.Turn"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.ExternalMirror",
      sha: "fb0ed3daa874ef0e291392ea0cc06075041f63f93b1dbe219022495db60891ef",
      note: "§3.4 upward ref: Ezagent.ActionSet.ExternalMirror"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Publisher.SessionImpl",
      sha: "75f24e859221df9667c3b318e48ece30eaec195c5dcdc87d75ae88923a82e5c5",
      note: "§3.4 upward ref: Ezagent.ActionSet.Publisher.SessionImpl"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Publisher.SessionImpl",
      sha: "7dc556288b526dbfe0364a778deff978dfdc3e8878985100c44d2588098ad11a",
      note: "§3.4 upward ref: Ezagent.ActionSet.Publisher.SessionImpl"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Session",
      sha: "7c837a7f8b6cbfdff002e9e1fd189b69b567e4734fd9b98ffdbb0c8c357d5cf3",
      note: "§3.4 upward ref: Ezagent.ActionSet.Session"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Session",
      sha: "7c837a7f8b6cbfdff002e9e1fd189b69b567e4734fd9b98ffdbb0c8c357d5cf3",
      note: "§3.4 upward ref: Ezagent.ActionSet.Session"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.SupervisorApproval",
      sha: "829f8478f18c9909d6ecdb4db5c28ddad1346fde08ae4c2da8cabfd06df3eeaf",
      note: "§3.4 upward ref: Ezagent.ActionSet.SupervisorApproval"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Surface",
      sha: "459e0c7e39012fd3f515ecb6b31dcd42d4069bad099f77d897b823fc4d44577a",
      note: "§3.4 upward ref: Ezagent.ActionSet.Surface"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Turn",
      sha: "692acd4c74d0c8d7f59555b7a548ef29416723db08699ada4951dec3a5bb1bbc",
      note: "§3.4 upward ref: Ezagent.ActionSet.Turn"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/ready_transition.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "64310a46cf6f71a529a365a2d0c49e5a422e9ac444202ac75d40d109440ee4a9",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/ready_transition.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "6e8ed9feb600c477e340e029f4d33048f0e2634438a2a658e7b40cb0221d5e00",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/ready_transition.ex",
      target: "Ezagent.DLQ",
      sha: "451b250ee0e1b6faca45e7730526173721e5ebe6ce6661b8c10e54195c85bc82",
      note: "§3.4 upward ref: Ezagent.DLQ"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.Cap.Grant",
      sha: "82526fee5ea7129bd3b6883e662addb11fedde17030f457c6f50e21b26f58f25",
      note: "§3.4 upward ref: Ezagent.Cap.Grant"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.Cap.RuntimeView",
      sha: "956a8f2555bb067f7c56df258fa3924fcd1fd75d3d4c78349a04231fb8f2122d",
      note: "§3.4 upward ref: Ezagent.Cap.RuntimeView"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.Cap.Verifier",
      sha: "55c9a846c0faf963f71c0912993cf7bb8dc361ae7b9ec6a8036dc5ad81a77e9c",
      note: "§3.4 upward ref: Ezagent.Cap.Verifier"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.Capability",
      sha: "20c0d41c46ec3b4e7856349c47450dd0a709d316cd6bb67629092eb9ede08889",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.Capability",
      sha: "3a2b871ba325494db758563e48b656cd9f466da992c4fc984d36e0e9def13cf4",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.Capability",
      sha: "8350b1541939e3f22de276eb5912ed95a68f168a0082f82431c4c806365d7fd7",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.Capability",
      sha: "c49e09f66ce3d89382f94a51fafdbdefb2421dc0b2f021937854f796186c20da",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.DispatchOrigin",
      sha: "27fb882d715f63685a8914019b2484cd5382cb916099701658cb8a1089aed944",
      note: "§3.4 upward ref: Ezagent.DispatchOrigin"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/effects.ex",
      target: "Ezagent.Capability",
      sha: "0445a4dce0a8c357560208232f9be8af846f917673329ed53fddd4a050a882f3",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/effects.ex",
      target: "Ezagent.EventLog",
      sha: "9cf76b8133853c0a05610f104f627b474cb55f6155a31ec3a9ef745ea6523ddc",
      note: "§3.4 upward ref: Ezagent.EventLog"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/effects.ex",
      target: "Ezagent.SagaRunner",
      sha: "ef074cdb5c47b2fdd3fe5fa85309c3063fc909960dd2403969bdd6b16e4e5ed3",
      note: "§3.4 upward ref: Ezagent.SagaRunner"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/effects.ex",
      target: "EzagentCore.PubSub",
      sha: "e66b3e8eb91a6a9af8cda61834d91b7f1b4cc73343dd79e5ea372021387c3cf0",
      note: "§3.4 upward ref: EzagentCore.PubSub"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/receipt.ex",
      target: "Ezagent.Capability",
      sha: "029277439afe24f003819ddaf2a3fed12f03ded53bf1a29e1d8ebdfbe331a85e",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/receipt.ex",
      target: "Ezagent.Capability",
      sha: "20c0d41c46ec3b4e7856349c47450dd0a709d316cd6bb67629092eb9ede08889",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/receipt.ex",
      target: "Ezagent.Capability",
      sha: "30da584543aee87bbb364249feeb21ae53c52e5db05649a03f95eaeccb2b5052",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/receipt.ex",
      target: "Ezagent.Capability",
      sha: "8350b1541939e3f22de276eb5912ed95a68f168a0082f82431c4c806365d7fd7",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime/receipt.ex",
      target: "Ezagent.Capability",
      sha: "a31eedbfaf2d81c68c6005a13d1f5261feb0195b5a0a0c51fa61c2ddd8da0eb3",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap",
      sha: "3e3381ebb5733b50e665b75aa67c66fe95a89281fd23c28359ebc36850d2b61b",
      note: "§3.4 upward ref: Ezagent.Cap"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "4d0921bbcc056f8f8fdf1d5422272b06af92c7d5349a321499c3324cdbc90d22",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "4d0921bbcc056f8f8fdf1d5422272b06af92c7d5349a321499c3324cdbc90d22",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "4d0921bbcc056f8f8fdf1d5422272b06af92c7d5349a321499c3324cdbc90d22",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "72d86bb597e01a796e98bf851d5dbbd8430f4bf3d25bf1171cb688981e60d906",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "7a2c911f4229e39cc280374ea57e4dba26a1126ef3dca37ae1473f8672f86ccb",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "7d7963b538d688edbb9de89fc3d2dd657f8db606fba0d35dbf98a350a8299f8a",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "9d4453a173de9ebb8af62ca3a0dc5664c1edbd3b4c20f36c76f79546c4bdb289",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "9d4453a173de9ebb8af62ca3a0dc5664c1edbd3b4c20f36c76f79546c4bdb289",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "9d4453a173de9ebb8af62ca3a0dc5664c1edbd3b4c20f36c76f79546c4bdb289",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "9d4453a173de9ebb8af62ca3a0dc5664c1edbd3b4c20f36c76f79546c4bdb289",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "9d4453a173de9ebb8af62ca3a0dc5664c1edbd3b4c20f36c76f79546c4bdb289",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "9d4453a173de9ebb8af62ca3a0dc5664c1edbd3b4c20f36c76f79546c4bdb289",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "ad5fd330b3b148e6763870cd23e3391d4edeaeb0444c62fc7c3a5174c3756970",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "3a32602e1373817c511d7b94dad2fbd74ab2ed5154352b97ecbd38a9b0f10d52",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.DeliveryOutbox",
      sha: "bde4c77e310658701f364ab5fac86ad3aed8c6c2092f0c436b33808c5d7e503b",
      note: "§3.4 upward ref: Ezagent.Cap.DeliveryOutbox"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Verifier",
      sha: "3be8153184be445a6c8e6d4762dab102b19142170e2831609f43cf97a7d5c115",
      note: "§3.4 upward ref: Ezagent.Cap.Verifier"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Capability",
      sha: "165b89045e9ef4144d363784a263098085adc9714573502365d9aef7c3e69c8c",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/snapshot.ex",
      target: "Ezagent.Cap",
      sha: "e6d1c812c7a66bab8771c5ce28d55720d0f735e3fa8bd598db4bba068036056f",
      note: "§3.4 upward ref: Ezagent.Cap"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/snapshot.ex",
      target: "Ezagent.Persistence",
      sha: "8379b08f78bf9ec2c8e591153dc1d3a757ade679489a8173591db71a95c07a2b",
      note: "§3.4 upward ref: Ezagent.Persistence"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle.ex",
      target: "Ezagent.Cap.Authority",
      sha: "478a2dbf2016b0b2922ed6cbaa2e96f2d381b77de57caa5c0cc93a2fe97926e4",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/local_runtime.ex",
      target: "Ezagent.WorkspaceOwnerGate",
      sha: "672ca424c7823eb5662f041b786aea51ff431260a5fc1655f11cb7249adb2428",
      note: "§3.4 upward ref: Ezagent.WorkspaceOwnerGate"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/local_runtime.ex",
      target: "Ezagent.WorkspaceOwnerGate",
      sha: "d450dc485faa7a980118039faf68174e26b24fdac87e5c9565a3dd8b1105b59e",
      note: "§3.4 upward ref: Ezagent.WorkspaceOwnerGate"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/router.ex",
      target: "Ezagent.EventLog",
      sha: "4d7f233ca1e0e5aac373b4e0dbb7cdfedb178db1148eb36ff58db6fb8233ed6b",
      note: "§3.4 upward ref: Ezagent.EventLog"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/router.ex",
      target: "Ezagent.EventLog",
      sha: "4d7f233ca1e0e5aac373b4e0dbb7cdfedb178db1148eb36ff58db6fb8233ed6b",
      note: "§3.4 upward ref: Ezagent.EventLog"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/router.ex",
      target: "Ezagent.SagaRunner",
      sha: "0a8513217e50c41de6b02d48eb23119a95ea2de66bcf5320796e5a39fab04638",
      note: "§3.4 upward ref: Ezagent.SagaRunner"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/router.ex",
      target: "Ezagent.SagaRunner",
      sha: "9ddf549bb0a16536d97b1a3446b05e12fd848e1d1fb8b88cbe22f464ed721b5d",
      note: "§3.4 upward ref: Ezagent.SagaRunner"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/router.ex",
      target: "Ezagent.SagaRunner",
      sha: "e8e4e8139b748ac05d4fed8c7e4c178435a8c6f187930457892839d6c68ce750",
      note: "§3.4 upward ref: Ezagent.SagaRunner"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/router.ex",
      target: "Ezagent.SagaRunner.Saga",
      sha: "61e1a3069d5b050338ce08ec1356b4da5eeac3cbdc8a4ddfa97bb564c57ff358",
      note: "§3.4 upward ref: Ezagent.SagaRunner.Saga"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/slice_change.ex",
      target: "EzagentCore.PubSub",
      sha: "29e2b5eae263d8be77742c3fadd54023974740dc463f44d4b1b70312f3ebd9f7",
      note: "§3.4 upward ref: EzagentCore.PubSub"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/slice_change.ex",
      target: "EzagentCore.PubSub",
      sha: "d41966bea829bcb6f50930e0d61d07ac5923b3006b2141bd888a1b329874e758",
      note: "§3.4 upward ref: EzagentCore.PubSub"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/slice_change.ex",
      target: "EzagentCore.PubSub",
      sha: "ee01b478fd8d592558b8c854d343d9d37735612387160eea340686e529ee8da2",
      note: "§3.4 upward ref: EzagentCore.PubSub"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/snapshot_store.ex",
      target: "Ezagent.Persistence",
      sha: "8379b08f78bf9ec2c8e591153dc1d3a757ade679489a8173591db71a95c07a2b",
      note: "§3.4 upward ref: Ezagent.Persistence"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/snapshot_store.ex",
      target: "EzagentCore.Repo",
      sha: "e7cda8f1f5fdb465c397cd93d5cca4b1e8318dd9ef1e5f86e0fd207818983858",
      note: "§3.4 upward ref: EzagentCore.Repo"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/spawn_registry.ex",
      target: "Ezagent.WorkspaceOwnerGate",
      sha: "3a6236f1f6e07a1637ad4ab3b1630d7f4c77b225379bbbc305a503a70e8f9447",
      note: "§3.4 upward ref: Ezagent.WorkspaceOwnerGate"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/universal_behaviors.ex",
      target: "Ezagent.ActionSet.Manage",
      sha: "2ee7ed9d5a02e5e83826a797cd43e32dec0bf02d3288f7757a827dfd974c1f9f",
      note: "§3.4 upward ref: Ezagent.ActionSet.Manage"
    }
  ],
  # The one reasoned reverse carve-out — LegacyCallbacks quoted Ezagent.Capability.cap/3.
  reverse_fixed: [
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior/legacy_callbacks.ex",
      target: "Ezagent.Capability",
      sha: "224e94edccb1c0ad7e362793b64f9044e86f5d0eb698ef63d983e7c54ea3d9af",
      note: "quoted Ezagent.Capability.cap/3 injected into using modules (§3.4 non-port)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior/legacy_callbacks.ex",
      target: "Ezagent.Capability",
      sha: "997bc4988d15b2c1350a19988141c4ffa0a228db21bbad0954703538a2d9a199",
      note: "quoted Ezagent.Capability.cap/3 injected into using modules (§3.4 non-port)"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/behavior/legacy_callbacks.ex",
      target: "Ezagent.Capability",
      sha: "d2b551cf65ab2543dd9e41df932ecdffba88686d2e8f53f285783fc4132b8cf5",
      note: "quoted Ezagent.Capability.cap/3 injected into using modules (§3.4 non-port)"
    }
  ]
}
