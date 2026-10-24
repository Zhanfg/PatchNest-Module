#!/usr/bin/env python3
"""Apply reviewed, fail-closed fixes to Mobilelegends74/hma-uidfake 325c827.

Refuse to patch unexpected upstream source. No configuration format, protocol ID,
or kernel module filename is changed.
"""
from pathlib import Path
import re

ROOT = Path(".")
changes = []

def replace(path, old, new):
    p = ROOT / path
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        raise RuntimeError(f"{path}: expected exactly one anchor, found {n}: {old[:90]!r}")
    p.write_text(s.replace(old, new))
    changes.append(path)

replace("src/main.c", """static int __init uidfake_init(void)
{
	int ret = policy_init();

	if (ret)
		return ret;

	uidfake_debug_init(uidfake_debug);

	netlink_init();
	pr_info("uidfake: ready (%d hook(s))\\n", hooks_install());
	return 0;
}""", """static int __init uidfake_init(void)
{
	int ret = policy_init();

	if (ret)
		return ret;
	uidfake_debug_init(uidfake_debug);
	ret = netlink_init();
	if (ret)
		goto err_debug;
	if (hooks_install() != 1) {
		ret = -ENODEV;
		goto err_hooks;
	}
	pr_info("uidfake: ready (hooks verified)\\n");
	return 0;

err_hooks:
	hooks_remove();
	netlink_exit();
err_debug:
	cancel_delayed_work_sync(&uidfake_debug_work);
	if (UF_DEBUG_ON())
		static_branch_disable(&uidfake_debug_key);
	policy_free();
	return ret;
}""")

replace("src/hooks.c", """	/* nothing was patched means nothing to tear down: there is no fallback */
	if (!main_table)
		return;

	unpatch_entries(main_table, g_hook, ARRAY_SIZE(g_hook));""", """	/* An LSM hook can be live even when syscall table installation failed. */
	if (main_table) {
	unpatch_entries(main_table, g_hook, ARRAY_SIZE(g_hook));""")
replace("src/hooks.c", """	main_table = NULL;

	/* the identity changes stay covered until the last moment */
	uidfake_lsm_remove();
}""", """	main_table = NULL;
	}
	/* Always uninstall the LSM hook, even after partial initialization. */
	uidfake_lsm_remove();
}""")
replace("src/hooks.c", """	g_status.native = native;
	g_status.compat = compat;
	if (native == g_status.native_expected)""", """	g_status.native = native;
	g_status.compat = compat;
	g_status.flags &= ~(KAUX_F_NATIVE | KAUX_F_COMPAT);
	if (native == g_status.native_expected)""")
replace("src/hooks.c", """	g_status.apk_updates++;
	if (failed == 0)""", """	g_status.apk_updates++;
	g_status.flags &= ~KAUX_F_APKS;
	if (failed == 0)""")

replace("src/include/uidfake.h", "void policy_apply(const u32 *pairs, u32 npairs);", "int policy_apply(const u32 *pairs, u32 npairs);")
replace("src/policy.c", "void policy_apply(const u32 *pairs, u32 npairs)", "int policy_apply(const u32 *pairs, u32 npairs)")
replace("src/policy.c", """	np = kzalloc(sizeof(*np), GFP_KERNEL);
	if (!np)
		return;""", """	np = kzalloc(sizeof(*np), GFP_KERNEL);
	if (!np)
		return -ENOMEM;""")
replace("src/policy.c", """	if (!ok) {
		kfree(np);
		return;
	}""", """	if (!ok) {
		kfree(np);
		return -EINVAL;
	}""")
replace("src/policy.c", """		np->nprobe, np->mirror ? "uid-hash" : "own-hash");
}""", """		np->nprobe, np->mirror ? "uid-hash" : "own-hash");
	return 0;
}""")
replace("src/policy.c", """		inode = igrab(d_backing_inode(p.dentry));
		g_path_put(&p);
		if (inode != NULL && UF_DEBUG_ON())""", """		inode = igrab(d_backing_inode(p.dentry));
		/* Keep the dentry pinned until the diagnostic reads its parent. */
		if (inode != NULL && UF_DEBUG_ON())""")
replace("src/policy.c", """		if (inode != NULL)
			iput(inode);
	}
	mutex_lock(&g_shadow_lock);""", """		g_path_put(&p);
		if (inode != NULL)
			iput(inode);
	}
	mutex_lock(&g_shadow_lock);""")
replace("src/policy.c", """if (size == 0 || off < 4u || off + size > len ||""", """if (size == 0 || off < 4u || off > len || size > len - off ||""")
replace("src/policy.c", """		if (uf_ti_mark_pending(current))
			pr_info("uidfake: iso birth uid %u marked, awaiting the apk it opens\\n",
				new_uid);""", """		if (uf_ti_mark_pending(current) && UF_DEBUG_ON())
			pr_info("uidfake: iso birth uid %u marked, awaiting the apk it opens\\n",
				new_uid);""")
replace("src/policy.c", """		if (app < UF_APP_SPAN)
			pr_info("uidfake: app birth uid %u -> app %u\\n",
				new_uid, app);""", """		if (app < UF_APP_SPAN && UF_DEBUG_ON())
			pr_info("uidfake: app birth uid %u -> app %u\\n",
				new_uid, app);""")

# Netlink: move the staging buffer to the apply owner without cloning a 2MiB
# allocation; free it after commit. New upload while apply runs has its own
# fresh staging buffer and is protected by the existing staging mutex.
replace("src/netlink.c", "#include <linux/slab.h>", "#include <linux/slab.h>\n#include <linux/vmalloc.h>")
replace("src/netlink.c", """	/*
	 * The staging buffer is allocated on the first upload, not at load: it is
	 * megabytes now, and the module is loaded while /data is barely there.
	 */
	if (g_staged == NULL)
		g_staged = kcalloc(KAUX_STAGED_BYTES / sizeof(*g_staged),
				   sizeof(*g_staged), GFP_KERNEL);
	if (g_staged == NULL) {
		rc = -ENOMEM;
		goto out;
	}

	if (kaux_blob(info, &p, &len) || len < sizeof(*b)) {""", """	if (kaux_blob(info, &p, &len) || len < sizeof(*b)) {""")
replace("src/netlink.c", """	if (b->kind > KAUX_KIND_MAX || b->bytes == 0 ||
	    b->bytes > KAUX_STAGED_BYTES) {
		rc = -EINVAL;
		goto out;
	}

	g_staged_kind = b->kind;""", """	if (b->kind > KAUX_KIND_MAX || b->bytes == 0 ||
	    b->bytes > KAUX_STAGED_BYTES) {
		rc = -EINVAL;
		goto out;
	}
	{
		void *next = kvzalloc(b->bytes, GFP_KERNEL);

		if (!next) {
			rc = -ENOMEM;
			goto out;
		}
		kvfree(g_staged);
		g_staged = next;
	}
	g_staged_kind = b->kind;""")
replace("src/netlink.c", """	if (g_staged_total == 0 || offset != g_staged_len ||""", """	if (g_staged == NULL || g_staged_total == 0 ||
	    offset != g_staged_len ||""")
replace("src/netlink.c", """	/* The blob is moved out of the staging buffer and applied with the lock
	 * dropped. Applying it resolves paths and touches inodes, and that can
	 * sleep: an apply inside this lock blocks the next page of the next upload,
	 * which is what turned an install into a hang.
	 */
	if (g_apply == NULL)
		g_apply = kcalloc(KAUX_STAGED_BYTES / sizeof(*g_apply),
				  sizeof(*g_apply), GFP_KERNEL);
	if (g_apply == NULL) {
		rc = -ENOMEM;
		goto out;
	}
	kind = g_staged_kind;
	bytes = g_staged_total;
	memcpy(g_apply, g_staged, bytes);
	g_staged_total = 0;""", """	/* Transfer ownership: no second 2MiB allocation or memcpy.
	 * Applying may sleep, so release the staging lock before calling it.
	 * g_apply_lock serializes commits while next upload uses fresh staging.
	 */
	kind = g_staged_kind;
	bytes = g_staged_total;
	g_apply = g_staged;
	g_staged = NULL;
	g_staged_total = 0;""")
replace("src/netlink.c", """			policy_apply(g_apply, bytes / 8u);""", """			rc = policy_apply(g_apply, bytes / 8u);""")
replace("src/netlink.c", """			uidfake_apk_apply(g_apply, bytes);""", """			rc = uidfake_apk_apply(g_apply, bytes);""")
replace("src/netlink.c", """	}
	mutex_unlock(&g_apply_lock);
	return rc;""", """	}
	kvfree(g_apply);
	g_apply = NULL;
	mutex_unlock(&g_apply_lock);
	return rc;""")
replace("src/netlink.c", """	kfree(g_staged);
	kfree(g_apply);""", """	kvfree(g_staged);
	kvfree(g_apply);""")

# source-level contract tests: reject hidden loss of functionality
for path, anchor in {
    "src/hooks.c": "uidfake32_ioprio_set",
    "src/lsm.c": "task_fix_setuid",
    "src/policy.c": "policy_lookup_core",
    "src/netlink.c": "KAUX_CMD_STAGE_COMMIT",
}.items():
    if anchor not in (ROOT / path).read_text():
        raise RuntimeError(f"missing retained capability {anchor} in {path}")

print("Applied reviewed optimization to", len(set(changes)), "sources:")
print("\n".join(sorted(set(changes))))
