"""SQLite real, temporário. Recebe o Dart SDK como primeiro argumento."""
import json, pathlib, re, sqlite3, subprocess, sys, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
SQL = json.loads(subprocess.check_output([sys.argv.pop(1), str(ROOT/'tool/verify_recovery.dart'), '--sql'], text=True))
SOURCE = (ROOT/'lib/turso_service.dart').read_text()
SCHEMA = re.search(r'CREATE TABLE IF NOT EXISTS galpao_racks \(.*?\n      \)', SOURCE, re.S).group(0)
class RackMigration(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:')
        self.db.execute(SCHEMA)
        for n in range(1,4):
            self.db.execute('INSERT INTO galpao_racks(posicao,ordem,produto_codigo,atualizado_em) VALUES(1,?,?,?)',(n,'TESTE','2026'))
        self.db.execute('ALTER TABLE galpao_racks ADD COLUMN rack_uuid TEXT')
        for sql in SQL: self.db.execute(sql)
    def tearDown(self): self.db.close()
    def test_backfill_and_idempotence(self):
        before=self.db.execute('SELECT id,rack_uuid FROM galpao_racks').fetchall()
        for sql in SQL: self.db.execute(sql)
        self.assertEqual(before,self.db.execute('SELECT id,rack_uuid FROM galpao_racks').fetchall())
        self.assertEqual(len({r[1] for r in before}),3)
    def test_renumber_preserves_identity(self):
        before=self.db.execute('SELECT rack_uuid FROM galpao_racks WHERE ordem=2').fetchone()[0]
        self.db.execute('DELETE FROM galpao_racks WHERE ordem=1')
        self.db.execute('UPDATE galpao_racks SET ordem=-(ordem-1) WHERE ordem>1')
        self.db.execute('UPDATE galpao_racks SET ordem=-ordem WHERE ordem<0')
        self.assertEqual(before,self.db.execute('SELECT rack_uuid FROM galpao_racks WHERE ordem=1').fetchone()[0])
    def test_old_client_insert_gets_identity(self):
        self.db.execute("INSERT INTO galpao_racks(posicao,ordem,produto_codigo,atualizado_em) VALUES(2,1,'TESTE','2026')")
        value=self.db.execute('SELECT rack_uuid FROM galpao_racks WHERE posicao=2').fetchone()[0]
        self.assertEqual(len(value),32)
    def test_identity_cannot_be_replaced_or_cleared(self):
        for value in ['outro',None,'']:
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute('UPDATE galpao_racks SET rack_uuid=? WHERE id=1',(value,))
    def test_duplicate_identity_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO galpao_racks(posicao,ordem,produto_codigo,atualizado_em,rack_uuid) VALUES(2,1,'TESTE','2026','legacy-1')")
    def test_outdated_identity_cannot_match_new_occupant(self):
        old=self.db.execute('SELECT rack_uuid FROM galpao_racks WHERE ordem=2').fetchone()[0]
        self.db.execute('DELETE FROM galpao_racks WHERE ordem=2')
        self.db.execute("INSERT INTO galpao_racks(posicao,ordem,produto_codigo,atualizado_em) VALUES(1,2,'TESTE','2026')")
        self.assertNotEqual(old,self.db.execute('SELECT rack_uuid FROM galpao_racks WHERE ordem=2').fetchone()[0])
unittest.main(verbosity=2)
