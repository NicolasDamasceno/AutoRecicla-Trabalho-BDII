
-- ==========================================
-- FILIAL
-- ==========================================

CREATE TABLE filial (
    id_filial   SERIAL PRIMARY KEY,
    nome_unidade VARCHAR(100) NOT NULL,
    cidade      VARCHAR(100) NOT NULL,
    endereco    VARCHAR(200) NOT NULL,
    cnpj        VARCHAR(18)  NOT NULL UNIQUE
);


-- ==========================================
-- VENDEDOR
-- ==========================================

CREATE TABLE vendedor (
    id_vendedor SERIAL PRIMARY KEY,
    nome        VARCHAR(100) NOT NULL,
    cpf         VARCHAR(14)  NOT NULL UNIQUE,
    id_filial   INT          NOT NULL,
    ativo       BOOLEAN      NOT NULL DEFAULT TRUE,

    CONSTRAINT fk_vendedor_filial
        FOREIGN KEY (id_filial)
        REFERENCES filial(id_filial)
);


-- ==========================================
-- CLIENTE
-- ==========================================

CREATE TABLE cliente (
    id_cliente SERIAL PRIMARY KEY,
    nome       VARCHAR(100) NOT NULL,
    cpf_cnpj   VARCHAR(18)  NOT NULL UNIQUE,
    telefone   VARCHAR(20),
    email      VARCHAR(150)
);


-- ==========================================
-- MARCA
-- ==========================================

CREATE TABLE marca (
    id_marca   SERIAL PRIMARY KEY,
    nome_marca VARCHAR(100) NOT NULL UNIQUE
);


-- ==========================================
-- MODELO
-- ==========================================

CREATE TABLE modelo (
    id_modelo   SERIAL PRIMARY KEY,
    nome_modelo VARCHAR(100) NOT NULL,
    id_marca    INT          NOT NULL,

    CONSTRAINT fk_modelo_marca
        FOREIGN KEY (id_marca)
        REFERENCES marca(id_marca)
);


-- ==========================================
-- CATEGORIA
-- ==========================================

CREATE TABLE categoria (
    id_categoria   SERIAL PRIMARY KEY,
    nome_categoria VARCHAR(100) NOT NULL UNIQUE
);


-- ==========================================
-- PEÇA
-- ==========================================

CREATE TABLE peca (
    id_peca    SERIAL PRIMARY KEY,
    nome_peca  VARCHAR(120) NOT NULL,
    valor      NUMERIC(10,2) NOT NULL,

    estado_conservacao VARCHAR(20) NOT NULL
        CHECK (
            estado_conservacao IN ('Novo', 'Seminovo', 'Usado')
        ),

    id_categoria INT NOT NULL,
    id_filial    INT NOT NULL,

    quantidade   INT NOT NULL
        CHECK (quantidade >= 0),

    CONSTRAINT fk_peca_categoria
        FOREIGN KEY (id_categoria)
        REFERENCES categoria(id_categoria),

    CONSTRAINT fk_peca_filial
        FOREIGN KEY (id_filial)
        REFERENCES filial(id_filial),

    CONSTRAINT unq_peca_filial_estado
        UNIQUE (nome_peca, estado_conservacao, id_filial)
);


-- ==========================================
-- COMPATIBILIDADE
-- ==========================================

CREATE TABLE compatibilidade (
    id_comp  SERIAL PRIMARY KEY,

    id_peca  INT NOT NULL,
    id_modelo INT NOT NULL,

    ano_inicio SMALLINT NOT NULL,
    ano_fim    SMALLINT NOT NULL,

    CONSTRAINT fk_comp_peca
        FOREIGN KEY (id_peca)
        REFERENCES peca(id_peca),

    CONSTRAINT fk_comp_modelo
        FOREIGN KEY (id_modelo)
        REFERENCES modelo(id_modelo),

    CONSTRAINT chk_anos
        CHECK (ano_inicio <= ano_fim),

    -- Permite múltiplos intervalos de ano para o mesmo par peça+modelo,
    -- mas impede duplicatas exatas
    CONSTRAINT unq_comp_peca_modelo_anos
        UNIQUE (id_peca, id_modelo, ano_inicio, ano_fim)
);


-- ==========================================
-- NOTA
-- ==========================================

-- ATENÇÃO: valor_total é calculado e atualizado via trigger
-- (a ser implementada em etapa futura) com base nos itens de nota_peca.
-- Por ora, a atualização é responsabilidade da camada de aplicação.

CREATE TABLE nota (
    id_nota    SERIAL PRIMARY KEY,

    data_criacao TIMESTAMP NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    data_venda TIMESTAMP,

    status     VARCHAR(20) NOT NULL
        DEFAULT 'Aberto'
        CHECK (
            status IN ('Aberto', 'Finalizado', 'Cancelado')
        ),

    forma_pagamento VARCHAR(50)
        CHECK (
            forma_pagamento IS NULL OR
            forma_pagamento IN (
                'Pix',
                'Dinheiro',
                'Cartão de Crédito',
                'Cartão de Débito',
                'Boleto'
            )
        ),

    valor_total NUMERIC(12,2)
        DEFAULT 0.00,

    id_cliente  INT NOT NULL,
    id_vendedor INT NOT NULL,

    CONSTRAINT fk_nota_cliente
        FOREIGN KEY (id_cliente)
        REFERENCES cliente(id_cliente),

    CONSTRAINT fk_nota_vendedor
        FOREIGN KEY (id_vendedor)
        REFERENCES vendedor(id_vendedor)
);


-- ==========================================
-- NOTA_PEÇA
-- ==========================================

CREATE TABLE nota_peca (
    id_nota  INT NOT NULL,
    id_peca  INT NOT NULL,

    valor_vendido NUMERIC(10,2) NOT NULL,

    quantidade INT NOT NULL
        CHECK (quantidade > 0),

    PRIMARY KEY (id_nota, id_peca),

    CONSTRAINT fk_notapeca_nota
        FOREIGN KEY (id_nota)
        REFERENCES nota(id_nota)
        ON DELETE CASCADE,

    CONSTRAINT fk_notapeca_peca
        FOREIGN KEY (id_peca)
        REFERENCES peca(id_peca)
);
