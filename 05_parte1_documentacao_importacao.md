# Parte 1 — Documentação do Processo de Importação

## 1. Ferramenta utilizada

A importação foi realizada com o **DBeaver**, conectado a uma instância
**PostgreSQL** local. Foram utilizados dois recursos principais da
ferramenta:

- **Data Transfer Wizard** (botão direito na tabela → *Import Data*), para
  trazer o conteúdo dos arquivos CSV/planilha diretamente para as tabelas
  de staging.
- **SQL Editor**, para execução dos scripts de criação de schema,
  transformação, validação e carga final.

O banco foi organizado em dois schemas:

- `staging` — tabelas intermediárias, com colunas 100% `text`, sem
  constraints, usadas apenas para receber o dado bruto sem risco de erro
  de tipo ou de chave durante a importação.
- `systock` — tabelas finais, com tipagem e constraints corretas,
  populadas a partir da staging já tratada.

> Observação: as tabelas finais foram criadas no schema `systock` em vez
> de `public` porque o usuário do banco não possuía permissão de `CREATE`
> no schema `public` (comportamento padrão em instâncias PostgreSQL 15+,
> que revogam privilégios de `public` por padrão).

## 2. Estrutura da planilha/arquivos de origem

Foram recebidos 5 arquivos, um por tabela do case: `vendas_systock.csv`,
`pedido_compra`, `entradas_mercadoria`, `produtos_filial` e `fornecedor`.
Cada um foi mapeado para uma tabela de staging homônima com sufixo `_raw`.

| Arquivo origem | Tabela staging | Colunas (tipo declarado no CSV) |
|---|---|---|
| vendas_systock.csv | staging.venda_raw | venda_id, data_emissao, horariomov, produto_id, qtde_vendida, valor_unitario, filial_id, item, unidade_medida |
| pedido_compra | staging.pedido_compra_raw | pedido_id, data_pedido, item, produto_id, descricao_produto, ordem_compra, qtde_pedida, filial_id, data_entrega, qtde_entregue, qtde_pendente, preco_compra, fornecedor_id |
| entradas_mercadoria | staging.entradas_mercadoria_raw | data_entrada, nro_nfe, item, produto_id, descricao_produto, qtde_recebida, filial_id, custo_unitario, ordem_compra |
| produtos_filial | staging.produtos_filial_raw | filial_id, produto_id, descricao, estoque, preco_unitario, preco_compra, preco_venda, idfonecedor |
| fornecedor | staging.fornecedor_raw | idfornecedor, razao_social |

Todas as colunas de staging foram criadas como `text`, independentemente
do tipo final esperado (data, numérico, inteiro), justamente para que a
importação bruta nunca falhasse por incompatibilidade de tipo — o
tratamento de tipo acontece depois, de forma controlada, na carga para o
schema `systock`.

## 3. Tratamentos aplicados

### 3.1 Conversão de datas (formato misto na origem)
Durante a carga, identificou-se que o campo de data não seguia um padrão
único: parte dos registros vinha em formato americano (`MM/DD/YYYY`, ex:
`1/28/2025`) e parte já vinha em formato ISO (`YYYY-MM-DD`, ex:
`2025-01-02`) — provavelmente porque uma coluna foi reconhecida como tipo
`date` nativo em algum ponto da exportação e outra permaneceu como texto.

Foi criada uma função (`staging.parse_data`) que tenta, nesta ordem: ISO →
`MM/DD/YYYY` → `DD/MM/YYYY`, retornando `NULL` apenas se nenhum formato
for reconhecido, em vez de interromper a carga com erro.

### 3.2 Normalização de separador decimal
Os campos numéricos (`qtde_vendida`, `valor_unitario`, `preco_compra`,
etc.) vinham no padrão brasileiro, com vírgula como separador decimal
(ex: `"78,93"`), o que quebra o `CAST` direto para `numeric`/`float8` no
Postgres. Foi criada a função `staging.br_to_num`, que remove eventual
separador de milhar (`.`) e converte a vírgula decimal para ponto antes do
`CAST`.

### 3.3 Validação de chave primária antes da carga
Cada `INSERT` final filtra explicitamente linhas cujo(s) campo(s) de chave
primária estejam nulos ou vazios (ex: `venda_id`, `produto_id`, `nro_nfe`,
`idfornecedor`). Isso foi necessário porque o arquivo de vendas continha
um volume muito alto de linhas em branco (ver item 4).

### 3.4 Correção de erros estruturais nas DDLs originais
As definições de tabela fornecidas no enunciado continham três problemas
estruturais que impediam a criação correta do schema, corrigidos antes da
carga:

- `entradas_mercadoria`: a `PRIMARY KEY` referenciava a coluna
  `ordem_compra`, que não constava na definição da tabela. A coluna foi
  adicionada, já que a relação entre entrada e pedido de compra depende
  dela (conforme observação do próprio enunciado).
- `produtos_filial`: faltava vírgula antes da cláusula `CONSTRAINT` (erro
  de sintaxe que impede a criação da tabela), e a `PRIMARY KEY` referenciava
  `idproduto`, coluna inexistente — a coluna real se chama `produto_id`.
- `fornecedor`: a `PRIMARY KEY` referenciava `idproduto`, coluna sem
  sentido semântico nessa tabela (um fornecedor pode atender vários
  produtos). A referência foi removida, mantendo `idfornecedor` como
  chave.
- A coluna `idforncedor` (grafia original, com erro de digitação) foi
  posteriormente renomeada para `idfornecedor` diretamente no banco via
  `ALTER TABLE ... RENAME COLUMN`, para manter consistência com o restante
  do modelo.

### 3.5 Geração de vínculo numérico produto–fornecedor
`fornecedor.idfornecedor` é uma chave de negócio `varchar`, enquanto
`produtos_filial.idfonecedor` é `int4` — os dois não podem se relacionar
diretamente. Foi implementada uma trigger (`systock.fn_gera_fornecedor_num_id`)
que gera automaticamente uma chave substituta numérica (`fornecedor_num_id`)
em `fornecedor` via `SEQUENCE`, e uma segunda trigger em `produtos_filial`
(`systock.fn_gera_idfonecedor_produto`) que preenche `idfonecedor`
automaticamente quando o valor não é informado no `INSERT`.

> A regra de atribuição usada (fornecedor de menor `fornecedor_num_id`
> disponível) é um valor padrão simplificado, não uma regra de negócio
> validada — esse ponto está listado explicitamente na Parte 4 como item a
> confirmar com o cliente.

## 4. Ajustes e correções realizadas durante o processo

Durante a execução, alguns problemas só ficaram evidentes ao rodar a carga
e comparar volume de dados entre staging e tabela final:

- **Volume anômalo de linhas vazias:** o arquivo de vendas trazia 999
  linhas no total, das quais apenas 33 (3,3%) continham dados reais — as
  demais 966 eram linhas em branco no final do arquivo. O mesmo padrão se
  repetiu, em proporções distintas, nas demais tabelas (`pedido_compra`:
  29 válidas de 999; `entradas_mercadoria` e `fornecedor`: 20 de 999;
  `produtos_filial`: 20 de 1.998). O filtro de chave primária (item 3.3)
  eliminou essas linhas automaticamente, sem perda de nenhum registro
  legítimo — confirmado comparando a contagem de linhas que passavam no
  filtro com a contagem de chaves distintas (nenhuma duplicidade real
  encontrada).
- **Trigger e dado pré-existente:** como as tabelas finais já haviam sido
  populadas antes da criação da trigger de vínculo produto-fornecedor
  (item 3.5), foi necessário rodar um `UPDATE` de backfill para aplicar a
  mesma regra retroativamente aos registros já existentes.
- **Registro de teste removido:** um registro de teste (`TESTE_TRIGGER`),
  inserido propositalmente para validar o funcionamento da trigger, foi
  removido da base antes da entrega final.

---

Os achados de qualidade de dado identificados durante esse processo
(formato de data misto, quantidades fracionadas, campo `qtde_pendente`
desatualizado, pedidos sem vínculo de ordem de compra, entre outros) estão
detalhados com consultas de apoio na **Parte 4 — Estratégia de Validação
com o Cliente**.
