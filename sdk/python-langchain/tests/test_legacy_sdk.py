"""A genuinely older installed Vela wheel: recall works; capture rejects before I/O."""
import asyncio,unittest
from test_langchain import Fixture, PROMPT
from vela_langchain import VelaLangChainError
class LegacyCompatibility(unittest.TestCase):
    def test_older_installed_sdk_cannot_mislabel_langchain_as_another_integration(self):
        f=Fixture()
        try:
            _,m=f.manager();t=f.turn(m);t.invoke(PROMPT);self.assertEqual(t.settled(1)['capture']['state'],'disabled')
            with self.assertRaises(VelaLangChainError) as error:f.manager(auto_capture=True)
            self.assertEqual(error.exception.code,'capture_integration_unavailable');self.assertEqual(f.rows(),[]);self.assertEqual(len(f.requests),1)
        finally:asyncio.run(f.aclose())
if __name__=='__main__':unittest.main(verbosity=2)
