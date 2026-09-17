#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec=importlib.util.spec_from_file_location("pack",Path(__file__).with_name("package-shared-helpers.py"))
pack=importlib.util.module_from_spec(spec); spec.loader.exec_module(pack)


class Packaging(unittest.TestCase):
    def test_detection_and_provider_scoped_repair(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); canonical=root/"shared/shell/validate-label.sh"
            canonical.parent.mkdir(parents=True)
            canonical.write_text("validate_label() {\n  return 0\n}\n")
            for prefix in ("plugins","codex/plugins"):
                for plugin,name in (("session-chat","validate_label"),("knowledge","kc_validate_label")):
                    path=root/prefix/plugin/"scripts/lib.sh"; path.parent.mkdir(parents=True)
                    path.write_text(f"# preserve\n{name}() {{\n  return 1\n}}\n# preserve end\n")
            self.assertEqual(len(pack.package(root)),4)
            pack.package(root,"codex",True)
            self.assertEqual(len(pack.package(root)),2)
            self.assertEqual(pack.package(root,"codex"),[])
            pack.package(root,"claude",True)
            self.assertEqual(pack.package(root),[])
            self.assertIn("# preserve end",(root/"plugins/knowledge/scripts/lib.sh").read_text())

    def test_labels(self):
        source=pack.ROOT/"shared/shell/validate-label.sh"
        for label,valid in (("agent-codex",True),("pane_42",True),("",False),
                            ("two words",False),("../pane",False),("a;echo",False),("a\nb",False)):
            result=subprocess.run(["bash","-c",'source "$1"; validate_label "$2"',"test",str(source),label],capture_output=True)
            self.assertEqual(result.returncode==0,valid,label)

if __name__=="__main__": unittest.main()
