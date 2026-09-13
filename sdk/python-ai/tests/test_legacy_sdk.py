"""Optional acceptance against a retained, actually installed pre-Responses SDK."""
import unittest
import vela
from dataclasses import replace
from vela_ai import VelaResponses, VelaResponsesError
from test_responses import Fixture


class LegacyAcceptance(unittest.TestCase):
    def test_legacy_sdk_reads_but_capture_fails_before_provider_dispatch(self):
        self.assertFalse(hasattr(vela,'MEMORY_INTEGRATIONS'))
        f=Fixture()
        try:
            f.seed('legacy-reference');client,m=f.sync()
            with self.assertRaises(VelaResponsesError) as error:VelaResponses(client,replace(f.binding,auto_capture=True))
            self.assertEqual(error.exception.code,'capture_integration_unavailable');self.assertEqual(len(f.requests),0);self.assertEqual(len(f.rows()),1)
            t=f.turn(m);self.assertEqual(t.create(input='SQLite legacy read').output_text,'Synthetic Responses completion.');self.assertEqual(t.settled(1)['capture']['state'],'disabled');self.assertEqual(len(f.requests),1);self.assertEqual(len(f.rows()),1)
        finally:f.close()


if __name__=='__main__':unittest.main(verbosity=2)
