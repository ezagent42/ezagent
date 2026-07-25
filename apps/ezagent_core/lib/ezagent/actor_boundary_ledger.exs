# Frozen SITE fingerprints for the actor-boundary gate — DATA ONLY.
# Loaded at compile time by `Ezagent.ActorBoundaryLedger` (a `.exs` data file,
# not a compiled module, so it stays out of the oversized-module `.ex` count).
# Each entry is `%{path, target, sha, note}` where `sha` is SHA-256 of the
# trimmed offending source line. Regenerate via the enumerator (see the gate).
%{
  # §4.4 reach-in census — migrates onto the §2.2 read surface (C1-C5; get_slice ratchet->C7).
  forward_ratchet: [
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
      target: "ReadyGate.status",
      sha: "8c05836c1b96135ccb6743eb16010565eda730f83a7b2620d875bb248adb4b50",
      note: "ReadyGate reach-in → read/3 + dispatch await (C3)"
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
      path: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      target: "Ezagent.SnapshotStore",
      sha: "c31c08b84d6bbf743380b518a71e7949258ad085a117cce09421415709dd4546",
      note: "durable/snapshot reach-in — full-state legacy dual-key (:sandbox|\"sandbox\" top-level); read_durable single-atom-key can't preserve it (like agent_flavor_resolver), deferred"
    },
    %{
      path: "apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "007498fd3e0fb1d62958eed18b328851e8f250ea5085d4d11f11d04933cf9b82",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
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
      path: "apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/per_binding_supervisor.ex",
      target: "Ezagent.Kind.Server",
      sha: "53d7545a958c5b711c728308372f39ee33b738fd84c080b29bffec48eb82f45a",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/per_binding_supervisor.ex",
      target: "Ezagent.Kind.Server",
      sha: "ade3de36d4e024452d0e58e4e0896e65a19a4d50834b2ae39d22b8a8cf70e72d",
      note: "§4.4 reach-in → §2.2 read surface (C1–C5)"
    },
    %{
      path: "apps/ezagent_domain_git/lib/ezagent/domain_git/task_access_supervisor.ex",
      target: "Ezagent.KindRegistry",
      sha: "d7be9688fdeb689151879e0f458c60d95248422758e069b61202be0a47703140",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/behavior/user_default_credential_source.ex",
      target: "Ezagent.SnapshotStore",
      sha: "139207f444c1d6a0d374534ef1a8ecda6d995392a30e94b3b9da51636e1e289a",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_shared_credential_source.ex",
      target: "Ezagent.SnapshotStore",
      sha: "139207f444c1d6a0d374534ef1a8ecda6d995392a30e94b3b9da51636e1e289a",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      target: "Ezagent.KindRegistry",
      sha: "0c59eb032044922fbe2493bc6433ece9b3ed332c03c604ed40baeec86b721300",
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
      sha: "a690bdf90814f0fbb3346866350976c2fb48489ff13b7e4991c00fe6060b4244",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
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
      path: "apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex",
      target: ":sys.get_state",
      sha: "65c7e1bd2c6b01e9a99a6e3fa42ca1e3282311403cafb345edd7a56e421a8c63",
      note: "PTY/Python sidecar inspects its OWN domain process, not a Kind (allowlisted debt)"
    },
    %{
      path: "apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex",
      target: ":sys.get_state",
      sha: "65c7e1bd2c6b01e9a99a6e3fa42ca1e3282311403cafb345edd7a56e421a8c63",
      note: "PTY/Python sidecar inspects its OWN domain process, not a Kind (allowlisted debt)"
    },
    %{
      path: "apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex",
      target: ":sys.get_state",
      sha: "d7a39f8c14a4f839260cda13194e249f6482f8c16e0ea1b1c25e6a6f0d1e34ee",
      note: "PTY/Python sidecar inspects its OWN domain process, not a Kind (allowlisted debt)"
    },
    %{
      path: "apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex",
      target: ":sys.get_state",
      sha: "d7a39f8c14a4f839260cda13194e249f6482f8c16e0ea1b1c25e6a6f0d1e34ee",
      note: "PTY/Python sidecar inspects its OWN domain process, not a Kind (allowlisted debt)"
    },
    %{
      path: "apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex",
      target: ":sys.get_state",
      sha: "d7a39f8c14a4f839260cda13194e249f6482f8c16e0ea1b1c25e6a6f0d1e34ee",
      note: "PTY/Python sidecar inspects its OWN domain process, not a Kind (allowlisted debt)"
    },
    %{
      path: "apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex",
      target: ":sys.get_state",
      sha: "d7a39f8c14a4f839260cda13194e249f6482f8c16e0ea1b1c25e6a6f0d1e34ee",
      note: "PTY/Python sidecar inspects its OWN domain process, not a Kind (allowlisted debt)"
    },
    %{
      path: "apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex",
      target: ":sys.get_state",
      sha: "d7a39f8c14a4f839260cda13194e249f6482f8c16e0ea1b1c25e6a6f0d1e34ee",
      note: "PTY/Python sidecar inspects its OWN domain process, not a Kind (allowlisted debt)"
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
      path: "apps/ezagent_domain_session/lib/ezagent/entity/session.ex",
      target: "Ezagent.KindRegistry",
      sha: "d92b05c20cd55e5c247aab6ff03077ba5c1eee0546d46cbff835c2842b73c441",
      note: "KindRegistry reach-in → alive?/self?/list_instances (C3)"
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
      target: "Kind.runtime_view",
      sha: "c387091dbc25db84a1591b3e86110f0aaef55b1719639cab2c47f246a65c9c7a",
      note: "runtime_view retires (§2.3) → resolve_action_subject/2 or read/3 (C3)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/agent_module_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "361bf548c2fa6af1e20460134ab4e975d0a372ca12942ca25ad5e4ac07d814ac",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/agent_module_resolver.ex",
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
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/listing.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "00a3d89f28a748d9aa7c144e21ffc9036b895b7ff609477900ddc8edcc9a8914",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/listing.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "1567ebd2fdeb22340fea9aadf7bea91cf7f54d91d2e18439b8c772074fbac2b5",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_resolver.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "fece7ad67f512dca90895a843b51543445a6081ced6d3d8cdb8bae770e661e91",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
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
      path: "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "007498fd3e0fb1d62958eed18b328851e8f250ea5085d4d11f11d04933cf9b82",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
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
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/bridge_adapter.ex",
      target: "Ezagent.SnapshotStore",
      sha: "c31c08b84d6bbf743380b518a71e7949258ad085a117cce09421415709dd4546",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "08167378fcdc013266bcf988883cc9b50cca37997c19019d3cc12a5941cb7e5b",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "1948de8ee9600c7d9f9d77aaefa565a0dfb2fa9198c3f8acae46da6fde763080",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "7ce204061293af1264724c62211cac61ed66d041eec4dc66f62e5d83163b6430",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "8e09468e04e2297903ebdcdfdbc5791561d8ed6376cc07080975df7940701826",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "8ff0738a810fdecdf5f70b27154fefd56ea8bf86b30bb48f4e2960388fa678af",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "a1efcb105ca1a58f57a701fe3259fc52e9f8f06efdf9231b9b16188345624e0e",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "f842893c649c9c2db7e396890833d3d959e65d948261347179ab8b51ff00bda8",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      target: "Ezagent.Kind.Snapshot",
      sha: "4247f9f0eb2d5e552782e7de1ec801400c2a7d4a75e7d68d8b65bc8ba03e9f8c",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/credential_bridge.ex",
      target: "Ezagent.SnapshotStore",
      sha: "89c27fb8c26f5ad0a792cef83abed1d6b9ef58d21cf6cf72a3a9bb3ed915ccd4",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/migrate.ex",
      target: "Ezagent.Ecto.KindSnapshot",
      sha: "fece7ad67f512dca90895a843b51543445a6081ced6d3d8cdb8bae770e661e91",
      note: "durable/snapshot reach-in → read_durable/3 + read/3 (C2)"
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
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Session",
      sha: "1e60eab48739d33a20dc5f8b88d56735999c39538de9f5b9c69d072795b8b53c",
      note: "§3.4 upward ref: Ezagent.ActionSet.Session"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Turn",
      sha: "81f519b27b69f0745ba2088de64c9f2f3e9225e5f40c400f6b5310fdb9a60509",
      note: "§3.4 upward ref: Ezagent.ActionSet.Turn"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Surface",
      sha: "8b07654223afd6811c76ba6aefa9085eea8ed3f866a00e56765fe6bd3a1469f3",
      note: "§3.4 upward ref: Ezagent.ActionSet.Surface"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.ConfigEvolve",
      sha: "503ac384a93c971cd29a163c492404dc55dd1d4c2ab8838ff03e8f2be88042f3",
      note: "§3.4 upward ref: Ezagent.ActionSet.ConfigEvolve"
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
      target: "Ezagent.ActionSet.ExternalMirror",
      sha: "3b2017dfe4961fc46d2be046706a75efdf678100a4aa2a724fdc136d9419d4e6",
      note: "§3.4 upward ref: Ezagent.ActionSet.ExternalMirror"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Turn",
      sha: "89df46823562e208dc18e5e193e8feb8154b0469f1cf9d002b92588e316ecea1",
      note: "§3.4 upward ref: Ezagent.ActionSet.Turn"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.ConfigEvolve",
      sha: "cfb140b459824d0d7d420b06c0c4769ccc9302aed95206e12e2245c5839076b3",
      note: "§3.4 upward ref: Ezagent.ActionSet.ConfigEvolve"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.ExternalMirror",
      sha: "6f92dbe6ffc7999a0a16c8ca620e8caa04b3184385aa97436cd184b85eaad31c",
      note: "§3.4 upward ref: Ezagent.ActionSet.ExternalMirror"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.Session",
      sha: "00b7b0167f819f7c6f709e89196fb898d589ccaee9e54f8bc58ee61d2a18e3c8",
      note: "§3.4 upward ref: Ezagent.ActionSet.Session"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/behavior_set.ex",
      target: "Ezagent.ActionSet.CurlAgent",
      sha: "5a83e8d6f378b03ed139e113fcff0f9848424d754c672a8972605489a1b08711",
      note: "§3.4 upward ref: Ezagent.ActionSet.CurlAgent"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Session",
      sha: "7c837a7f8b6cbfdff002e9e1fd189b69b567e4734fd9b98ffdbb0c8c357d5cf3",
      note: "§3.4 upward ref: Ezagent.ActionSet.Session"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Publisher.SessionImpl",
      sha: "7dc556288b526dbfe0364a778deff978dfdc3e8878985100c44d2588098ad11a",
      note: "§3.4 upward ref: Ezagent.ActionSet.Publisher.SessionImpl"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.ExternalMirror",
      sha: "fb0ed3daa874ef0e291392ea0cc06075041f63f93b1dbe219022495db60891ef",
      note: "§3.4 upward ref: Ezagent.ActionSet.ExternalMirror"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Session",
      sha: "7c837a7f8b6cbfdff002e9e1fd189b69b567e4734fd9b98ffdbb0c8c357d5cf3",
      note: "§3.4 upward ref: Ezagent.ActionSet.Session"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Turn",
      sha: "692acd4c74d0c8d7f59555b7a548ef29416723db08699ada4951dec3a5bb1bbc",
      note: "§3.4 upward ref: Ezagent.ActionSet.Turn"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Surface",
      sha: "459e0c7e39012fd3f515ecb6b31dcd42d4069bad099f77d897b823fc4d44577a",
      note: "§3.4 upward ref: Ezagent.ActionSet.Surface"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.SupervisorApproval",
      sha: "829f8478f18c9909d6ecdb4db5c28ddad1346fde08ae4c2da8cabfd06df3eeaf",
      note: "§3.4 upward ref: Ezagent.ActionSet.SupervisorApproval"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex",
      target: "Ezagent.ActionSet.Publisher.SessionImpl",
      sha: "75f24e859221df9667c3b318e48ece30eaec195c5dcdc87d75ae88923a82e5c5",
      note: "§3.4 upward ref: Ezagent.ActionSet.Publisher.SessionImpl"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
      target: "Ezagent.Cap.RuntimeView",
      sha: "956a8f2555bb067f7c56df258fa3924fcd1fd75d3d4c78349a04231fb8f2122d",
      note: "§3.4 upward ref: Ezagent.Cap.RuntimeView"
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
      sha: "4d0921bbcc056f8f8fdf1d5422272b06af92c7d5349a321499c3324cdbc90d22",
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
      target: "Ezagent.Cap.Authority",
      sha: "4d0921bbcc056f8f8fdf1d5422272b06af92c7d5349a321499c3324cdbc90d22",
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
      target: "Ezagent.Cap",
      sha: "3e3381ebb5733b50e665b75aa67c66fe95a89281fd23c28359ebc36850d2b61b",
      note: "§3.4 upward ref: Ezagent.Cap"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "72d86bb597e01a796e98bf851d5dbbd8430f4bf3d25bf1171cb688981e60d906",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Capability",
      sha: "165b89045e9ef4144d363784a263098085adc9714573502365d9aef7c3e69c8c",
      note: "§3.4 upward ref: Ezagent.Capability"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Authority",
      sha: "9d4453a173de9ebb8af62ca3a0dc5664c1edbd3b4c20f36c76f79546c4bdb289",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/server.ex",
      target: "Ezagent.Cap.Verifier",
      sha: "3be8153184be445a6c8e6d4762dab102b19142170e2831609f43cf97a7d5c115",
      note: "§3.4 upward ref: Ezagent.Cap.Verifier"
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
      sha: "4d0921bbcc056f8f8fdf1d5422272b06af92c7d5349a321499c3324cdbc90d22",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/kind/snapshot.ex",
      target: "Ezagent.Cap",
      sha: "e6d1c812c7a66bab8771c5ce28d55720d0f735e3fa8bd598db4bba068036056f",
      note: "§3.4 upward ref: Ezagent.Cap"
    },
    %{
      path: "apps/ezagent_core/lib/ezagent/lifecycle.ex",
      target: "Ezagent.Cap.Authority",
      sha: "478a2dbf2016b0b2922ed6cbaa2e96f2d381b77de57caa5c0cc93a2fe97926e4",
      note: "§3.4 upward ref: Ezagent.Cap.Authority"
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
