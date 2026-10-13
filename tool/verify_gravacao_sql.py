"""Lotes de gravação (lib/gravacao_lote.dart) rodando em SQLite real.

Recebe o executável `dart` como primeiro argumento. O esquema vem do próprio
lib/turso_service.dart, como em verify_rack_sql.py. Um lote que falha no meio
é seguido de ROLLBACK — é o que o servidor faz quando o stream do pipeline
fecha com a transação aberta.
"""
import json, pathlib, re, sqlite3, subprocess, sys, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DART = sys.argv.pop(1)
SOURCE = (ROOT / 'lib/turso_service.dart').read_text()


def tabela(nome):
    return re.search(
        r'CREATE TABLE IF NOT EXISTS %s \(.*?\n      \)' % nome, SOURCE, re.S
    ).group(0)


SCHEMA = [tabela(n) for n in (
    'app_mutacoes_aplicadas', 'estoque_localizado', 'contagens_log',
    'galpao_racks', 'barracao_enderecos')]


def op(tipo, local, **kw):
    base = {'tipo': tipo, 'banco': 'b', 'criadaEm': '2026-10-13T09:00:00',
            'local': local, 'rotulo': str(local)}
    base.update(kw)
    return base


OPS = {
    # Galpão, posição 5
    'l1': op('galpaoLancar', 5, uuid='u1', produtoCodigo='100',
             produtoNome="ÓLEO D'ÁGUA; 20L", quantidade=12.0),
    'l2': op('galpaoLancar', 5, uuid='u2', produtoCodigo='200', produtoNome='B', quantidade=7.5),
    'l3': op('galpaoLancar', 5, uuid='u3', produtoCodigo='EST:9', produtoNome='C · ZÉ', quantidade=3.0),
    'l4': op('galpaoLancar', 5, uuid='u4', produtoCodigo='100', produtoNome='A', quantidade=1.0),
    'l5': op('galpaoLancar', 5, uuid='u5', produtoCodigo='100', produtoNome='A', quantidade=1.0),
    'a1': op('galpaoAjustar', 5, uuid='a1', rackUuid='u1', produtoCodigo='100', quantidade=30.0),
    'e2': op('galpaoEsvaziar', 5, uuid='e2', rackUuid='u2'),
    'e2b': op('galpaoEsvaziar', 5, uuid='e2b', rackUuid='u2'),
    'a2': op('galpaoAjustar', 5, uuid='a2', rackUuid='u2', quantidade=1.0),
    'eOutraPos': op('galpaoEsvaziar', 6, uuid='e9', rackUuid='u1'),
    'eLegado': op('galpaoEsvaziar', 7, uuid='eL', rackUuid='legacy-1', origem='baixa_teste'),
    # Barracão, endereço 1
    'b1': op('barracaoAtribuir', 1, uuid='b1', produtoCodigo='300', produtoNome='Adubo', quantidade=40.0),
    'b2': op('barracaoAtribuir', 1, uuid='b2', produtoCodigo='300', produtoNome='Adubo', quantidade=25.0),
    'b3': op('barracaoAtribuir', 1, uuid='b3', produtoCodigo='400', produtoNome='Outro', quantidade=5.0),
    'bEst': op('barracaoAtribuir', 1, uuid='bE', produtoCodigo='EST:1', produtoNome='Bag · ANA', quantidade=1.0),
    'bv': op('barracaoEsvaziar', 1, uuid='bv'),
    'bAusente': op('barracaoAtribuir', 99, uuid='bx', produtoCodigo='300', quantidade=1.0),
}

GERADO = json.loads(subprocess.run(
    [DART, str(ROOT / 'tool/verify_gravacao_lote.dart')],
    input=json.dumps(OPS), capture_output=True, text=True, check=True).stdout)


class Lotes(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:', isolation_level=None)
        for sql in SCHEMA:
            self.db.execute(sql)
        self.db.execute('ALTER TABLE galpao_racks ADD COLUMN rack_uuid TEXT')
        for sql in GERADO['__migracao_rack']:
            self.db.execute(sql)
        self.db.execute(
            "INSERT INTO barracao_enderecos (id, rotulo, pos_x, pos_z, atualizado_em) "
            "VALUES (1, 'BAR-01', 0, 0, 'x')")

    def tearDown(self):
        self.db.close()

    def lote(self, nome):
        """Roda o lote; devolve a mensagem de erro, ou None."""
        try:
            self.db.executescript(GERADO[nome])
            return None
        except sqlite3.Error as e:
            if self.db.in_transaction:
                self.db.execute('ROLLBACK')
            return str(e)

    def foto(self):
        return [self.db.execute('SELECT * FROM %s ORDER BY 1' % t).fetchall()
                for t in ('galpao_racks', 'estoque_localizado', 'contagens_log',
                          'app_mutacoes_aplicadas', 'barracao_enderecos')]

    def pilha(self, posicao=5):
        return self.db.execute(
            'SELECT ordem, rack_uuid, produto_codigo, produto_nome, quantidade '
            'FROM galpao_racks WHERE posicao = ? ORDER BY ordem', (posicao,)).fetchall()

    def espelho(self, tipo='galpao', num=5):
        return self.db.execute(
            'SELECT produto_codigo, andar_ou_nivel, quantidade FROM estoque_localizado '
            'WHERE local_tipo = ? AND local_num = ? ORDER BY andar_ou_nivel', (tipo, num)).fetchall()

    def test_lancar_grava_rack_espelho_log_e_carimbo(self):
        self.assertIsNone(self.lote('l1'))
        self.assertEqual(self.pilha(), [(1, 'u1', '100', "ÓLEO D'ÁGUA; 20L", 12.0)])
        self.assertEqual(self.espelho(), [('100', 1, 12.0)])
        log = self.db.execute('SELECT produto_codigo, endereco, qtd_anterior, qtd_nova, origem, registrado_em FROM contagens_log').fetchall()
        self.assertEqual(log, [('100', 'GALPAO·5·N1', None, 12.0, 'gondolas_app_galpao', '2026-10-13T09:00:00.000')])
        self.assertEqual(self.db.execute('SELECT uuid, operacao FROM app_mutacoes_aplicadas').fetchall(), [('u1', 'galpao.lancar')])

    def test_reenviar_o_mesmo_lote_nao_duplica(self):
        self.assertIsNone(self.lote('l1'))
        antes = self.foto()
        self.assertIsNone(self.lote('l1'))
        self.assertEqual(antes, self.foto())

    def test_pilha_cheia_aborta_tudo_com_motivo(self):
        for n in ('l1', 'l2', 'l3', 'l4'):
            self.assertIsNone(self.lote(n))
        antes = self.foto()
        erro = self.lote('l5')
        self.assertIn('GONDOLAS_CONFLITO:pilha_cheia', erro)
        self.assertEqual(antes, self.foto())

    def test_reenvio_de_lancamento_ja_gravado_passa_mesmo_com_pilha_cheia(self):
        for n in ('l1', 'l2', 'l3', 'l4'):
            self.assertIsNone(self.lote(n))
        # A resposta do l1 "se perdeu" e a fila reenvia com a pilha já cheia.
        self.assertIsNone(self.lote('l1'))
        self.assertEqual(len(self.pilha()), 4)

    def test_estocado_ocupa_a_vaga_mas_nao_entra_no_espelho(self):
        for n in ('l1', 'l2', 'l3'):
            self.assertIsNone(self.lote(n))
        self.assertEqual([r[2] for r in self.pilha()], ['100', '200', 'EST:9'])
        self.assertEqual(self.espelho(), [('100', 1, 12.0), ('200', 2, 7.5)])

    def test_ajustar_pelo_uuid_do_rack(self):
        for n in ('l1', 'l2'):
            self.lote(n)
        self.assertIsNone(self.lote('a1'))
        self.assertEqual(self.pilha()[0][4], 30.0)
        self.assertEqual(self.espelho(), [('100', 1, 30.0), ('200', 2, 7.5)])
        ultimo = self.db.execute('SELECT endereco, qtd_anterior, qtd_nova FROM contagens_log ORDER BY id DESC LIMIT 1').fetchone()
        self.assertEqual(ultimo, ('GALPAO·5·N1', 12.0, 30.0))
        antes = self.foto()
        self.assertIsNone(self.lote('a1'))
        self.assertEqual(antes, self.foto())

    def test_esvaziar_o_do_meio_desce_a_pilha_e_preserva_identidade(self):
        for n in ('l1', 'l2', 'l3', 'l4'):
            self.lote(n)
        self.assertIsNone(self.lote('e2'))
        self.assertEqual([(r[0], r[1]) for r in self.pilha()], [(1, 'u1'), (2, 'u3'), (3, 'u4')])
        self.assertEqual(self.espelho(), [('100', 1, 12.0), ('100', 3, 1.0)])
        ultimo = self.db.execute('SELECT produto_codigo, endereco, qtd_anterior, qtd_nova, origem FROM contagens_log ORDER BY id DESC LIMIT 1').fetchone()
        self.assertEqual(ultimo, ('200', 'GALPAO·5·N2', 7.5, 0.0, 'gondolas_app_galpao_exclusao'))
        antes = self.foto()
        self.assertIsNone(self.lote('e2'))
        self.assertEqual(antes, self.foto())

    def test_rack_que_ja_saiu_e_conflito_e_nao_mexe_em_nada(self):
        for n in ('l1', 'l2', 'l3'):
            self.lote(n)
        self.assertIsNone(self.lote('e2'))
        antes = self.foto()
        self.assertIn('GONDOLAS_CONFLITO:rack_ausente', self.lote('e2b'))
        self.assertIn('GONDOLAS_CONFLITO:rack_ausente', self.lote('a2'))
        self.assertEqual(antes, self.foto())

    def test_rack_de_outra_posicao_nao_e_alvo(self):
        self.lote('l1')
        antes = self.foto()
        self.assertIn('rack_ausente', self.lote('eOutraPos'))
        self.assertEqual(antes, self.foto())

    def test_rack_legado_e_origem_da_baixa(self):
        # Rack migrado (legacy-<id>) com outro em cima, lançado por app antigo.
        self.db.execute("INSERT INTO galpao_racks (posicao, ordem, produto_codigo, atualizado_em, rack_uuid) VALUES (7, 1, 'X', 'x', 'legacy-1')")
        self.db.execute("INSERT INTO galpao_racks (posicao, ordem, produto_codigo, atualizado_em) VALUES (7, 2, 'Y', 'x')")
        self.assertIsNone(self.lote('eLegado'))
        self.assertEqual([(r[0], r[2]) for r in self.pilha(7)], [(1, 'Y')])
        self.assertEqual(self.db.execute('SELECT origem FROM contagens_log').fetchone()[0], 'baixa_teste')

    def test_barracao_atribuir_corrigir_trocar_e_esvaziar(self):
        self.assertIsNone(self.lote('b1'))
        self.assertEqual(self.espelho('barracao', 1), [('300', 0, 40.0)])
        self.assertIsNone(self.lote('b2'))
        self.assertIsNone(self.lote('b3'))
        logs = self.db.execute('SELECT produto_codigo, endereco, qtd_anterior, qtd_nova FROM contagens_log ORDER BY id').fetchall()
        self.assertEqual(logs, [('300', 'BARRACAO·BAR-01', None, 40.0),
                                ('300', 'BARRACAO·BAR-01', 40.0, 25.0),
                                ('400', 'BARRACAO·BAR-01', None, 5.0)])
        self.assertEqual(self.espelho('barracao', 1), [('400', 0, 5.0)])
        antes = self.foto()
        self.assertIsNone(self.lote('b3'))
        self.assertEqual(antes, self.foto())
        self.assertIsNone(self.lote('bv'))
        self.assertEqual(self.db.execute('SELECT produto_codigo, quantidade FROM barracao_enderecos').fetchall(), [('', 0.0)])
        self.assertEqual(self.espelho('barracao', 1), [])
        self.assertEqual(self.db.execute('SELECT origem FROM contagens_log ORDER BY id DESC').fetchone()[0], 'gondolas_app_barracao_exclusao')

    def test_barracao_estocado_fora_do_espelho_e_endereco_ausente(self):
        self.assertIsNone(self.lote('bEst'))
        self.assertEqual(self.espelho('barracao', 1), [])
        antes = self.foto()
        self.assertIn('GONDOLAS_CONFLITO:endereco_ausente', self.lote('bAusente'))
        self.assertEqual(antes, self.foto())


def esquema_da_abertura():
    """Os comandos que _criarEsquema junta num batch, lidos do próprio código."""
    ini = SOURCE.index('  Future<void> _criarEsquema(')
    corpo = SOURCE[ini:SOURCE.index('await client.batch(esquema.join', ini)]
    literal = re.compile(r"'''(.*?)'''|'((?:[^'\\]|\\.)*)'", re.S)
    comandos = []
    for bloco in re.findall(r'esquema\.add\((.*?)\);\n', corpo, re.S):
        comandos.append(''.join(a or b for a, b in literal.findall(bloco)))
    return comandos


class Abertura(unittest.TestCase):
    def test_esquema_num_lote_so_e_idempotente(self):
        comandos = esquema_da_abertura()
        self.assertGreaterEqual(len(comandos), 18)
        db = sqlite3.connect(':memory:', isolation_level=None)
        for _ in range(2):
            db.executescript(';\n'.join(comandos))
        tabelas = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertTrue({'galpao_racks', 'barracao_enderecos', 'app_mutacoes_aplicadas',
                         'estoque_localizado', 'contagens_log', 'galpao_posicoes'} <= tabelas)
        # Banco antigo: o lote acrescenta a coluna e a identidade de uma vez.
        db.execute("INSERT INTO galpao_racks (posicao, ordem, produto_codigo, atualizado_em) VALUES (1, 1, 'X', 'x')")
        db.executescript(GERADO['__lote_rack_novo'])
        self.assertEqual(db.execute('SELECT rack_uuid FROM galpao_racks').fetchone()[0], 'legacy-1')
        # Reabertura: sem o ALTER, o resto não muda nada.
        db.executescript(GERADO['__lote_rack_existente'])
        self.assertEqual(db.execute('SELECT rack_uuid FROM galpao_racks').fetchone()[0], 'legacy-1')
        # A planta do galpão num upsert só, duas vezes.
        for _ in range(2):
            db.executescript(GERADO['__seed_galpao'])
        self.assertEqual(db.execute('SELECT COUNT(*) FROM galpao_posicoes').fetchone()[0], 129)
        db.close()


unittest.main(verbosity=2)
