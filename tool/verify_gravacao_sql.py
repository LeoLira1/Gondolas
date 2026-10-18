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
    'galpao_racks', 'galpao_rack_itens', 'barracao_enderecos')]


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
    # Rack misto: u1 (posição 5, N1) recebe mais produtos
    'm1': op('galpaoAdicionarProduto', 5, uuid='i1', rackUuid='u1', produtoCodigo='501', produtoNome='M1', quantidade=2.0),
    'm2': op('galpaoAdicionarProduto', 5, uuid='i2', rackUuid='u1', produtoCodigo='502', produtoNome='M2', quantidade=3.0),
    'm3': op('galpaoAdicionarProduto', 5, uuid='i3', rackUuid='u1', produtoCodigo='503', produtoNome='M3', quantidade=4.0),
    'm4': op('galpaoAdicionarProduto', 5, uuid='i4', rackUuid='u1', produtoCodigo='504', produtoNome='M4', quantidade=5.0),
    'm5': op('galpaoAdicionarProduto', 5, uuid='i5', rackUuid='u1', produtoCodigo='505', produtoNome='M5', quantidade=6.0),
    'mRepetidoItem': op('galpaoAdicionarProduto', 5, uuid='i6', rackUuid='u1', produtoCodigo='501', quantidade=1.0),
    'mRepetidoPrincipal': op('galpaoAdicionarProduto', 5, uuid='i7', rackUuid='u1', produtoCodigo='100', quantidade=1.0),
    'mRackAusente': op('galpaoAdicionarProduto', 5, uuid='i8', rackUuid='zz', produtoCodigo='509', quantidade=1.0),
    'mAjusta': op('galpaoAjustar', 5, uuid='ma', rackUuid='u1', itemUuid='i2', quantidade=9.0),
    'mAjustaAusente': op('galpaoAjustar', 5, uuid='mb', rackUuid='u1', itemUuid='nao', quantidade=9.0),
    'mTiraItem': op('galpaoRemoverProduto', 5, uuid='mt', rackUuid='u1', itemUuid='i1'),
    'mTiraItemDeNovo': op('galpaoRemoverProduto', 5, uuid='mt2', rackUuid='u1', itemUuid='i1'),
    'mTiraPrincipal': op('galpaoRemoverProduto', 5, uuid='mp', rackUuid='u1'),
    'mTiraPrincipal2': op('galpaoRemoverProduto', 5, uuid='mp2', rackUuid='u1'),
    'mTiraPrincipal3': op('galpaoRemoverProduto', 5, uuid='mp3', rackUuid='u1'),
    'mTiraPrincipalBaixa': op('galpaoRemoverProduto', 5, uuid='mpb', rackUuid='u1', origem='baixa_teste'),
    'mEsvazia': op('galpaoEsvaziar', 5, uuid='me', rackUuid='u1'),
    'e1Debaixo': op('galpaoEsvaziar', 5, uuid='ed', rackUuid='u1'),
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

    def itens(self, rack='u1'):
        return self.db.execute(
            'SELECT item_uuid, produto_codigo, quantidade FROM galpao_rack_itens '
            'WHERE rack_uuid = ? ORDER BY id', (rack,)).fetchall()

    def pilha(self, posicao=5):
        return self.db.execute(
            'SELECT ordem, rack_uuid, produto_codigo, produto_nome, quantidade '
            'FROM galpao_racks WHERE posicao = ? ORDER BY ordem', (posicao,)).fetchall()

    def espelho(self, tipo='galpao', num=5):
        return self.db.execute(
            'SELECT produto_codigo, andar_ou_nivel, quantidade FROM estoque_localizado '
            'WHERE local_tipo = ? AND local_num = ? ORDER BY andar_ou_nivel, produto_codigo', (tipo, num)).fetchall()

    # ── Rack misto ──────────────────────────────────────────────────────────

    def test_misto_adicionar_entra_no_espelho_e_no_log_e_e_idempotente(self):
        for n in ('l1', 'l2', 'm1'):
            self.assertIsNone(self.lote(n))
        self.assertEqual(self.itens(), [('i1', '501', 2.0)])
        # O rack não mudou de nível nem de produto principal.
        self.assertEqual([(r[0], r[1], r[2]) for r in self.pilha()], [(1, 'u1', '100'), (2, 'u2', '200')])
        self.assertEqual(self.espelho(), [('100', 1, 12.0), ('501', 1, 2.0), ('200', 2, 7.5)])
        ultimo = self.db.execute('SELECT produto_codigo, endereco, qtd_anterior, qtd_nova FROM contagens_log ORDER BY id DESC LIMIT 1').fetchone()
        self.assertEqual(ultimo, ('501', 'GALPAO·5·N1', None, 2.0))
        antes = self.foto()
        self.assertIsNone(self.lote('m1'))
        self.assertEqual(antes, self.foto())

    def test_misto_no_maximo_cinco_produtos(self):
        for n in ('l1', 'm1', 'm2', 'm3', 'm4'):
            self.assertIsNone(self.lote(n))
        antes = self.foto()
        self.assertIn('GONDOLAS_CONFLITO:rack_cheio', self.lote('m5'))
        self.assertEqual(antes, self.foto())
        # Reenvio de um que já entrou passa, mesmo com o rack cheio.
        self.assertIsNone(self.lote('m4'))
        self.assertEqual(len(self.itens()), 4)

    def test_misto_produto_repetido_e_rack_ausente_sao_conflito(self):
        for n in ('l1', 'm1'):
            self.lote(n)
        antes = self.foto()
        self.assertIn('GONDOLAS_CONFLITO:produto_repetido', self.lote('mRepetidoItem'))
        self.assertIn('GONDOLAS_CONFLITO:produto_repetido', self.lote('mRepetidoPrincipal'))
        self.assertIn('GONDOLAS_CONFLITO:rack_ausente', self.lote('mRackAusente'))
        self.assertEqual(antes, self.foto())

    def test_misto_ajustar_item(self):
        for n in ('l1', 'm1', 'm2'):
            self.lote(n)
        self.assertIsNone(self.lote('mAjusta'))
        self.assertEqual(self.itens(), [('i1', '501', 2.0), ('i2', '502', 9.0)])
        self.assertEqual(self.pilha()[0][4], 12.0)
        self.assertEqual(self.espelho(), [('100', 1, 12.0), ('501', 1, 2.0), ('502', 1, 9.0)])
        ultimo = self.db.execute('SELECT produto_codigo, endereco, qtd_anterior, qtd_nova FROM contagens_log ORDER BY id DESC LIMIT 1').fetchone()
        self.assertEqual(ultimo, ('502', 'GALPAO·5·N1', 3.0, 9.0))
        antes = self.foto()
        self.assertIsNone(self.lote('mAjusta'))
        self.assertEqual(antes, self.foto())
        self.assertIn('GONDOLAS_CONFLITO:item_ausente', self.lote('mAjustaAusente'))
        self.assertEqual(antes, self.foto())

    def test_misto_tirar_item_deixa_o_rack(self):
        for n in ('l1', 'l2', 'm1', 'm2'):
            self.lote(n)
        self.assertIsNone(self.lote('mTiraItem'))
        self.assertEqual(self.itens(), [('i2', '502', 3.0)])
        self.assertEqual([(r[0], r[1]) for r in self.pilha()], [(1, 'u1'), (2, 'u2')])
        self.assertEqual(self.espelho(), [('100', 1, 12.0), ('502', 1, 3.0), ('200', 2, 7.5)])
        ultimo = self.db.execute('SELECT produto_codigo, qtd_anterior, qtd_nova, origem FROM contagens_log ORDER BY id DESC LIMIT 1').fetchone()
        self.assertEqual(ultimo, ('501', 2.0, 0.0, 'gondolas_app_galpao_exclusao'))
        antes = self.foto()
        self.assertIsNone(self.lote('mTiraItem'))
        self.assertEqual(antes, self.foto())
        # Outra gravação querendo o mesmo item, que já saiu: conflito.
        self.assertIn('GONDOLAS_CONFLITO:item_ausente', self.lote('mTiraItemDeNovo'))
        self.assertEqual(antes, self.foto())

    def test_misto_tirar_principal_promove_o_item_mais_antigo(self):
        for n in ('l1', 'l2', 'm1', 'm2'):
            self.lote(n)
        self.assertIsNone(self.lote('mTiraPrincipal'))
        self.assertEqual(self.pilha()[0], (1, 'u1', '501', 'M1', 2.0))
        self.assertEqual(self.itens(), [('i2', '502', 3.0)])
        self.assertEqual(self.espelho(), [('501', 1, 2.0), ('502', 1, 3.0), ('200', 2, 7.5)])
        log = self.db.execute('SELECT produto_codigo, qtd_anterior, qtd_nova FROM contagens_log ORDER BY id DESC LIMIT 1').fetchone()
        self.assertEqual(log, ('100', 12.0, 0.0))
        antes = self.foto()
        self.assertIsNone(self.lote('mTiraPrincipal'))
        self.assertEqual(antes, self.foto())
        # De novo: o 502 sobe, e o rack fica sem item.
        self.assertIsNone(self.lote('mTiraPrincipal2'))
        self.assertEqual(self.pilha()[0], (1, 'u1', '502', 'M2', 3.0))
        self.assertEqual(self.itens(), [])
        # O último produto saindo é o rack saindo: a pilha desce.
        self.assertIsNone(self.lote('mTiraPrincipal3'))
        self.assertEqual([(r[0], r[1], r[2]) for r in self.pilha()], [(1, 'u2', '200')])
        self.assertEqual(self.espelho(), [('200', 1, 7.5)])

    def test_tirar_principal_de_rack_comum_e_esvaziar(self):
        for n in ('l1', 'l2', 'l3'):
            self.lote(n)
        self.assertIsNone(self.lote('mTiraPrincipalBaixa'))
        self.assertEqual([(r[0], r[1]) for r in self.pilha()], [(1, 'u2'), (2, 'u3')])
        self.assertEqual(self.espelho(), [('200', 1, 7.5)])
        self.assertEqual(self.db.execute('SELECT origem FROM contagens_log ORDER BY id DESC').fetchone()[0], 'baixa_teste')

    def test_misto_esvaziar_tira_o_rack_com_todos_os_produtos(self):
        for n in ('l1', 'l2', 'm1', 'm2'):
            self.lote(n)
        self.assertIsNone(self.lote('mEsvazia'))
        self.assertEqual([(r[0], r[1]) for r in self.pilha()], [(1, 'u2')])
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM galpao_rack_itens').fetchone()[0], 0)
        self.assertEqual(self.espelho(), [('200', 1, 7.5)])
        logs = self.db.execute("SELECT produto_codigo, qtd_anterior, qtd_nova FROM contagens_log WHERE qtd_nova = 0 ORDER BY id").fetchall()
        self.assertEqual(logs, [('100', 12.0, 0.0), ('501', 2.0, 0.0), ('502', 3.0, 0.0)])

    def test_misto_item_desce_junto_com_o_rack(self):
        for n in ('l1', 'l2'):
            self.lote(n)
        self.assertIsNone(self.lote('m1'))
        # Item no rack de cima (u2): tira o de baixo e o item acompanha.
        self.db.execute("UPDATE galpao_rack_itens SET rack_uuid = 'u2'")
        self.assertIsNone(self.lote('e1Debaixo'))
        self.assertEqual(self.pilha()[0][:2], (1, 'u2'))
        self.assertEqual(self.espelho(), [('200', 1, 7.5), ('501', 1, 2.0)])

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
        self.assertTrue({'galpao_racks', 'galpao_rack_itens', 'barracao_enderecos', 'app_mutacoes_aplicadas',
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
