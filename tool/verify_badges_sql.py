"""Selos das prateleiras (lib/badges_estoque.dart) contra o SQL antigo, em SQLite real.

Recebe o executável `dart` como primeiro argumento. Para cada cenário, monta as
tabelas, roda o JOIN que os selos usavam até a fase 2 (o caminho antigo) e o
SQL das cópias novas, e confere que as funções Dart dão exatamente os mesmos
endereços desatualizados, divergentes e positivos.
"""
import json, pathlib, re, sqlite3, subprocess, sys, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DART = sys.argv.pop(1)
SOURCE = (ROOT / 'lib/turso_service.dart').read_text()
ESTOQUE_LOCALIZADO = re.search(
    r'CREATE TABLE IF NOT EXISTS estoque_localizado \(.*?\n      \)', SOURCE, re.S
).group(0)
NOVO = json.loads(subprocess.run(
    [DART, str(ROOT / 'tool/verify_badges.dart'), '--sql'],
    capture_output=True, text=True, check=True).stdout)

# O SQL que os selos usavam (estoque_localizado_service.dart, antes da fase 2).
ANTIGO_DESATUALIZADOS = '''
  SELECT el.produto_codigo, el.local_tipo, el.local_num, el.face_ou_coluna,
         el.andar_ou_nivel, el.atualizado_em, uc.ultima
  FROM estoque_localizado el
  JOIN (
    SELECT produto_codigo, MAX(dt) AS ultima FROM (
      SELECT produto_id AS produto_codigo, contado_em AS dt
      FROM inventario_cicli WHERE contado_em IS NOT NULL
      UNION ALL
      SELECT codigo AS produto_codigo, {col} AS dt
      FROM contagem_itens WHERE status != 'pendente' AND {col} IS NOT NULL
    )
    GROUP BY produto_codigo
  ) uc ON uc.produto_codigo = el.produto_codigo
'''
ANTIGO_DIVERGENTES = '''
  SELECT el.produto_codigo, el.local_tipo, el.local_num,
         el.face_ou_coluna, el.andar_ou_nivel,
         em.qtd_contada_ciclo, em.qtd_sistema_na_contagem
  FROM estoque_localizado el
  JOIN estoque_mestre em ON em.codigo = el.produto_codigo
  WHERE em.status_ciclo = 'divergencia'
'''
ENDERECOS = ('SELECT id, produto_codigo, local_tipo, local_num, face_ou_coluna, '
             'andar_ou_nivel, quantidade, atualizado_em FROM estoque_localizado')


def linhas(db, sql):
    cur = db.execute(sql)
    nomes = [c[0] for c in cur.description]
    return [dict(zip(nomes, r)) for r in cur.fetchall()]


class Selos(unittest.TestCase):
    def banco(self, produto_id_tipo='TEXT', com_confirmado=True, codigo_mestre='TEXT'):
        db = sqlite3.connect(':memory:')
        db.execute(ESTOQUE_LOCALIZADO)
        db.execute('CREATE TABLE inventario_cicli (id INTEGER PRIMARY KEY, '
                   f'data_contagem TEXT, produto_id {produto_id_tipo}, contado_em TEXT)')
        colunas = 'codigo TEXT, status TEXT, registrado_em TEXT'
        if com_confirmado:
            colunas += ', confirmado_em TEXT'
        db.execute(f'CREATE TABLE contagem_itens (id INTEGER PRIMARY KEY, {colunas})')
        db.execute(f'CREATE TABLE estoque_mestre (codigo {codigo_mestre}, status_ciclo TEXT, '
                   'qtd_contada_ciclo INTEGER, qtd_sistema_na_contagem INTEGER)')
        return db

    def endereco(self, db, codigo, atualizado, tipo='gondola', num=1, face=1, andar=0):
        db.execute('INSERT INTO estoque_localizado (produto_codigo, local_tipo, local_num, '
                   'face_ou_coluna, andar_ou_nivel, quantidade, atualizado_em) '
                   'VALUES (?, ?, ?, ?, ?, 1, ?)', (codigo, tipo, num, face, andar, atualizado))

    def conferir(self, db, col='confirmado_em'):
        entrada = {
            'antigo_desatualizados': linhas(db, ANTIGO_DESATUALIZADOS.format(col=col)),
            'antigo_divergentes': linhas(db, ANTIGO_DIVERGENTES),
            'enderecos': linhas(db, ENDERECOS),
            'ciclico': linhas(db, NOVO['ciclico']),
            'itens': linhas(db, NOVO['itens_' + col]),
            'divergentes_ciclo': linhas(db, NOVO['divergentes']),
        }
        saida = json.loads(subprocess.run(
            [DART, str(ROOT / 'tool/verify_badges.dart')],
            input=json.dumps(entrada), capture_output=True, text=True, check=True).stdout)
        self.assertEqual(saida['antigo'], saida['novo'])
        return saida['novo']

    def test_contagem_confirmada_depois_do_endereco(self):
        db = self.banco()
        self.endereco(db, 'A', '2026-10-14T08:00:00')
        self.endereco(db, 'A', '2026-10-14T11:00:00', face=2)
        self.endereco(db, 'B', '2026-10-14T08:00:00')
        db.execute("INSERT INTO contagem_itens (codigo, status, confirmado_em, registrado_em) "
                   "VALUES ('A', 'ok', '2026-10-14T10:00:00', '2026-10-13')")
        db.execute("INSERT INTO contagem_itens (codigo, status, confirmado_em, registrado_em) "
                   "VALUES ('B', 'pendente', '2026-10-14T10:00:00', '2026-10-13')")
        novo = self.conferir(db)
        self.assertEqual(novo['desatualizados'], ['A|gondola|1|1|0'])

    def test_datas_em_formatos_misturados_seguem_o_max_de_texto(self):
        db = self.banco()
        self.endereco(db, 'A', '2026-10-14T12:00:00')
        # Mesmo dia: o 'T' vence o espaço no MAX de texto, mesmo sendo mais cedo.
        db.execute("INSERT INTO inventario_cicli (data_contagem, produto_id, contado_em) "
                   "VALUES ('2026-10-14', 'A', '2026-10-14 15:00:00')")
        db.execute("INSERT INTO contagem_itens (codigo, status, confirmado_em) "
                   "VALUES ('A', 'divergencia', '2026-10-14T09:00:00')")
        novo = self.conferir(db)
        self.assertEqual(novo['desatualizados'], [])

    def test_produto_id_inteiro_nunca_casava(self):
        db = self.banco(produto_id_tipo='')  # sem afinidade: o inteiro fica inteiro
        self.endereco(db, '254185', '2026-10-01T00:00:00')
        self.endereco(db, '254185', '2026-10-01T00:00:00', tipo='estante', num=3)
        db.execute("INSERT INTO inventario_cicli (data_contagem, produto_id, contado_em) "
                   "VALUES ('2026-10-14', 254185, '2026-10-14T10:00:00')")
        # E o mesmo código como texto, mais velho, no outro app: grupo à parte.
        db.execute("INSERT INTO contagem_itens (codigo, status, confirmado_em) "
                   "VALUES ('254185', 'ok', '2026-09-01T10:00:00')")
        novo = self.conferir(db)
        # O inteiro nunca casava; só o texto, mais velho que o endereço.
        self.assertEqual(novo['desatualizados'], [])

    def test_produto_id_declarado_inteiro_tambem_nao_casa(self):
        db = self.banco(produto_id_tipo='INTEGER')
        self.endereco(db, '254185', '2026-10-01T00:00:00')
        db.execute("INSERT INTO inventario_cicli (data_contagem, produto_id, contado_em) "
                   "VALUES ('2026-10-14', '254185', '2026-10-14T10:00:00')")
        self.conferir(db)

    def test_codigo_mestre_inteiro_casa_pelo_numero(self):
        db = self.banco(codigo_mestre='INTEGER')
        for codigo in ('123', '00123', '123.0', ' 123', 'abc', 'US1'):
            self.endereco(db, codigo, '2026-10-14T08:00:00')
        db.execute("INSERT INTO estoque_mestre VALUES (123, 'divergencia', 12, 10), "
                   "('US1', 'divergencia', 1, 2)")
        novo = self.conferir(db)
        self.assertEqual(len(novo['divergentes']), 5)

    def test_datas_ilegiveis_e_nulas_ficam_de_fora(self):
        db = self.banco()
        self.endereco(db, 'A', 'ontem')
        self.endereco(db, 'B', '2026-10-01T00:00:00')
        self.endereco(db, 'C', '2026-10-01T00:00:00')
        db.execute("INSERT INTO contagem_itens (codigo, status, confirmado_em) "
                   "VALUES ('A', 'ok', '2026-10-14T10:00:00'), ('B', 'ok', 'depois'), "
                   "('C', 'ok', NULL)")
        self.conferir(db)

    def test_coluna_registrado_em(self):
        db = self.banco(com_confirmado=False)
        self.endereco(db, 'A', '2026-10-01T00:00:00')
        db.execute("INSERT INTO contagem_itens (codigo, status, registrado_em) "
                   "VALUES ('A', 'ok', '2026-10-14 10:00:00')")
        novo = self.conferir(db, col='registrado_em')
        self.assertEqual(novo['desatualizados'], ['A|gondola|1|1|0'])

    def test_divergentes_e_positivos(self):
        db = self.banco()
        for codigo in ('MAIS', 'MENOS', 'OK'):
            self.endereco(db, codigo, '2026-10-14T08:00:00')
            self.endereco(db, codigo, '2026-10-14T08:00:00', tipo='galpao', num=52, face=0, andar=2)
        db.execute("INSERT INTO estoque_mestre VALUES ('MAIS', 'divergencia', 12, 10), "
                   "('MENOS', 'divergencia', 8, 10), ('OK', 'ok', 10, 10), "
                   "('SEM_ENDERECO', 'divergencia', 1, 0)")
        novo = self.conferir(db)
        self.assertEqual(len(novo['divergentes']), 4)
        self.assertEqual(novo['positivas'], ['MAIS|galpao|52|0|2', 'MAIS|gondola|1|1|0'])

    def test_varios_produtos_e_locais(self):
        db = self.banco()
        datas = ['2026-10-0%dT0%d:00:00' % (d, h) for d in range(1, 10) for h in range(0, 10, 3)]
        for i, data in enumerate(datas):
            self.endereco(db, 'P%d' % (i % 7), data, tipo=('gondola', 'estante', 'galpao')[i % 3],
                          num=i % 11, face=i % 5, andar=i % 3)
        for i in range(7):
            db.execute("INSERT INTO inventario_cicli (data_contagem, produto_id, contado_em) "
                       "VALUES (?, ?, ?)", ('2026-10-05', 'P%d' % i, '2026-10-0%d 12:00:00' % (i + 2)))
            db.execute("INSERT INTO contagem_itens (codigo, status, confirmado_em) VALUES (?, ?, ?)",
                       ('P%d' % i, ('ok', 'pendente', 'divergencia')[i % 3], '2026-10-0%dT06:00:00' % (i + 3)))
            db.execute("INSERT INTO estoque_mestre VALUES (?, ?, ?, ?)",
                       ('P%d' % i, ('divergencia', 'ok')[i % 2], 10 + i, 12))
        novo = self.conferir(db)
        self.assertTrue(novo['desatualizados'])
        self.assertTrue(novo['divergentes'])


unittest.main(verbosity=2)
