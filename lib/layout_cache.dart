/// Cache em memória dos layouts já lidos do banco, chaveado pelo número da
/// estrutura (gôndola ou estante).
///
/// Existe porque as páginas de cena são alcançadas por `Navigator.push` e
/// destruídas no `pop`: o `Map<int, List<Caixa…>>` que cada `State` mantinha
/// morria junto, então voltar ao mapa e reabrir a mesma gôndola refazia a
/// consulta. Aqui o cache vive no `TursoService`, que sobrevive à navegação e
/// é quem executa todas as escritas — ou seja, é o único lugar de onde dá para
/// invalidar no momento certo, sem depender de notificação.
///
/// Classe pura de propósito: sem Flutter, sem libsql, sem relógio. Isso a torna
/// testável direto em `flutter test` (os serviços do app são singletons
/// amarrados ao `LibsqlClient`, sem costura de injeção). A validade NÃO é por
/// TTL — quem invalida são os pontos de escrita e de sincronização, que sabem
/// exatamente quando os dados mudaram.
class CacheDeLayout<T> {
  final Map<int, List<T>> _porNumero = {};

  /// Linhas em cache da estrutura, ou null se nunca foram lidas (ou foram
  /// invalidadas). Null e lista vazia são coisas diferentes: vazia significa
  /// "consultado, e a estrutura não tem nenhuma caixa".
  List<T>? ler(int numero) => _porNumero[numero];

  /// Guarda as linhas da estrutura. A lista é copiada e congelada para que
  /// nenhum chamador mute o cache por acidente segurando a referência.
  void gravar(int numero, List<T> itens) {
    _porNumero[numero] = List<T>.unmodifiable(itens);
  }

  void invalidar(int numero) {
    _porNumero.remove(numero);
  }

  void invalidarTudo() {
    _porNumero.clear();
  }

  /// Quantas estruturas estão em cache. Para teste e telemetria.
  int get tamanho => _porNumero.length;
}
