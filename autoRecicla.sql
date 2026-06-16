DROP ROLE IF EXISTS role_admin;
DROP ROLE IF EXISTS role_gerente;
DROP ROLE IF EXISTS role_vendedor;
DROP USER IF EXISTS usr_admin;
DROP USER IF EXISTS usr_gerente;
DROP USER IF EXISTS usr_vendedor;

CREATE TABLE filial (
    id_filial    SERIAL PRIMARY KEY,
    nome_unidade VARCHAR(100) NOT NULL,
    cidade       VARCHAR(100) NOT NULL,
    endereco     VARCHAR(200) NOT NULL,
    cnpj         VARCHAR(18)  NOT NULL UNIQUE
);

CREATE TABLE vendedor (
    id_vendedor SERIAL PRIMARY KEY,
    nome        VARCHAR(100) NOT NULL,
    cpf         VARCHAR(14)  NOT NULL UNIQUE,
    id_filial   INT          NOT NULL,
    ativo       BOOLEAN      NOT NULL DEFAULT TRUE,
    cargo       VARCHAR(20)  NOT NULL DEFAULT 'Vendedor'
        CHECK (cargo IN ('Vendedor', 'Gerente', 'Admin')),

    CONSTRAINT fk_vendedor_filial
        FOREIGN KEY (id_filial) REFERENCES filial(id_filial)
);

CREATE TABLE cliente (
    id_cliente SERIAL PRIMARY KEY,
    nome       VARCHAR(100) NOT NULL,
    cpf_cnpj   VARCHAR(18)  NOT NULL UNIQUE,
    telefone   VARCHAR(20),
    email      VARCHAR(150)
);

CREATE TABLE marca (
    id_marca   SERIAL PRIMARY KEY,
    nome_marca VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE modelo (
    id_modelo   SERIAL PRIMARY KEY,
    nome_modelo VARCHAR(100) NOT NULL,
    id_marca    INT          NOT NULL,

    CONSTRAINT fk_modelo_marca
        FOREIGN KEY (id_marca) REFERENCES marca(id_marca)
);

CREATE TABLE categoria (
    id_categoria   SERIAL PRIMARY KEY,
    nome_categoria VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE peca (
    id_peca    SERIAL PRIMARY KEY,
    nome_peca  VARCHAR(120)  NOT NULL,
    valor      NUMERIC(10,2) NOT NULL CHECK (valor > 0),
    estado_conservacao VARCHAR(20) NOT NULL
        CHECK (estado_conservacao IN ('Novo', 'Seminovo', 'Usado')),
    id_categoria INT NOT NULL,
    id_filial    INT NOT NULL,
    quantidade INT NOT NULL
        CHECK (quantidade >= 0),

    CONSTRAINT fk_peca_categoria
        FOREIGN KEY (id_categoria) REFERENCES categoria(id_categoria),
    CONSTRAINT fk_peca_filial
        FOREIGN KEY (id_filial) REFERENCES filial(id_filial),
    CONSTRAINT unq_peca_filial_estado
        UNIQUE (nome_peca, estado_conservacao, id_filial)
);

CREATE TABLE compatibilidade (
    id_comp   SERIAL PRIMARY KEY,
    id_peca   INT      NOT NULL,
    id_modelo INT      NOT NULL,
    ano_inicio SMALLINT NOT NULL,
    ano_fim    SMALLINT NOT NULL,

    CONSTRAINT fk_comp_peca
        FOREIGN KEY (id_peca)   REFERENCES peca(id_peca),
    CONSTRAINT fk_comp_modelo
        FOREIGN KEY (id_modelo) REFERENCES modelo(id_modelo),
    CONSTRAINT chk_anos
        CHECK (ano_inicio <= ano_fim),
    CONSTRAINT unq_comp_peca_modelo_anos
        UNIQUE (id_peca, id_modelo, ano_inicio, ano_fim)
);

CREATE TABLE nota (
    id_nota    SERIAL PRIMARY KEY,
    data_criacao TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    data_venda   TIMESTAMP,
    status VARCHAR(20) NOT NULL DEFAULT 'Aberto'
        CHECK (status IN ('Aberto', 'Finalizado', 'Cancelado')),
    forma_pagamento VARCHAR(50)
        CHECK (
            forma_pagamento IS NULL OR
            forma_pagamento IN (
                'Pix', 'Dinheiro', 'Cartão de Crédito',
                'Cartão de Débito', 'Boleto'
            )
        ),
    valor_total NUMERIC(12,2) DEFAULT 0.00,
    id_cliente  INT NOT NULL,
    id_vendedor INT NOT NULL,

    CONSTRAINT fk_nota_cliente
        FOREIGN KEY (id_cliente)  REFERENCES cliente(id_cliente),
    CONSTRAINT fk_nota_vendedor
        FOREIGN KEY (id_vendedor) REFERENCES vendedor(id_vendedor)
);

CREATE TABLE nota_peca (
    id_nota  INT NOT NULL,
    id_peca  INT NOT NULL,
    valor_vendido NUMERIC(10,2) NOT NULL CHECK (valor_vendido > 0),
    quantidade INT NOT NULL CHECK (quantidade > 0),

    PRIMARY KEY (id_nota, id_peca),

    CONSTRAINT fk_notapeca_nota
        FOREIGN KEY (id_nota) REFERENCES nota(id_nota)
        ON DELETE CASCADE,
    CONSTRAINT fk_notapeca_peca
        FOREIGN KEY (id_peca) REFERENCES peca(id_peca)
);


-- =============================================================
-- TRIGGERS
-- =============================================================

-- Validar abertura de nota

CREATE OR REPLACE FUNCTION fn_validar_abertura_nota()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM vendedor
         WHERE id_vendedor = NEW.id_vendedor
           AND ativo = TRUE
    ) THEN
        RAISE EXCEPTION
            'Vendedor % está inativo e não pode abrir notas.',
            NEW.id_vendedor
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_validar_abertura_nota
    BEFORE INSERT ON nota
    FOR EACH ROW
    EXECUTE FUNCTION fn_validar_abertura_nota();


-- Bloquear desativação de vendedor com notas em aberto

CREATE OR REPLACE FUNCTION fn_bloquear_desativacao_vendedor()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.ativo = TRUE AND NEW.ativo = FALSE THEN
        IF EXISTS (
            SELECT 1 FROM nota
             WHERE id_vendedor = NEW.id_vendedor
               AND status = 'Aberto'
        ) THEN
            RAISE EXCEPTION
                'Vendedor % possui notas em aberto e não pode ser desativado.',
                NEW.id_vendedor
                USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_bloquear_desativacao_vendedor
    BEFORE UPDATE OF ativo ON vendedor
    FOR EACH ROW
    EXECUTE FUNCTION fn_bloquear_desativacao_vendedor();


-- Validar filial do vendedor ao inserir item na nota

CREATE OR REPLACE FUNCTION fn_validar_filial_vendedor()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_filial_vendedor INT;
    v_filial_peca     INT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.id_peca <> NEW.id_peca OR OLD.id_nota <> NEW.id_nota THEN
            RAISE EXCEPTION
                'Não é permitido alterar id_nota ou id_peca. Remova o item e insira novamente.'
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    SELECT v.id_filial
      INTO v_filial_vendedor
      FROM nota n
      JOIN vendedor v ON v.id_vendedor = n.id_vendedor
     WHERE n.id_nota = NEW.id_nota;

    SELECT p.id_filial
      INTO v_filial_peca
      FROM peca p
     WHERE p.id_peca = NEW.id_peca;

    IF v_filial_vendedor IS DISTINCT FROM v_filial_peca THEN
        RAISE EXCEPTION
            'Filial incompatível: a peça % pertence à filial % mas o vendedor atua na filial %.',
            NEW.id_peca, v_filial_peca, v_filial_vendedor
            USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_validar_filial_vendedor
    BEFORE INSERT OR UPDATE ON nota_peca
    FOR EACH ROW
    EXECUTE FUNCTION fn_validar_filial_vendedor();


-- Gerenciar estoque


CREATE OR REPLACE FUNCTION fn_gerenciar_estoque()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_status_nota VARCHAR(20);
    v_delta       INT := 0;
    v_id_peca     INT;
    v_qtd_atual   INT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        SELECT status INTO v_status_nota FROM nota WHERE id_nota = OLD.id_nota;
        IF v_status_nota = 'Aberto' THEN
            v_delta   :=  OLD.quantidade;
            v_id_peca := OLD.id_peca;
        ELSE
            RETURN OLD;
        END IF;

    ELSIF TG_OP = 'INSERT' THEN
        SELECT status INTO v_status_nota FROM nota WHERE id_nota = NEW.id_nota;
        IF v_status_nota <> 'Aberto' THEN
            RAISE EXCEPTION
                'Não é possível adicionar itens a uma nota com status "%".',
                v_status_nota
                USING ERRCODE = 'P0001';
        END IF;
        v_delta   := -NEW.quantidade;
        v_id_peca :=  NEW.id_peca;

    ELSIF TG_OP = 'UPDATE' THEN
        SELECT status INTO v_status_nota FROM nota WHERE id_nota = NEW.id_nota;
        IF v_status_nota <> 'Aberto' THEN
            RAISE EXCEPTION
                'Não é possível alterar itens de uma nota com status "%".',
                v_status_nota
                USING ERRCODE = 'P0001';
        END IF;
        v_delta   := OLD.quantidade - NEW.quantidade;
        v_id_peca := NEW.id_peca;
    END IF;

    SELECT quantidade INTO v_qtd_atual
      FROM peca WHERE id_peca = v_id_peca FOR UPDATE;

    IF v_delta < 0 THEN
        IF v_qtd_atual + v_delta < 0 THEN
            RAISE EXCEPTION
                'Estoque insuficiente para a peça % (disponível: %, solicitado: %).',
                v_id_peca, v_qtd_atual, ABS(v_delta)
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    UPDATE peca
       SET quantidade = quantidade + v_delta
     WHERE id_peca = v_id_peca;

    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_gerenciar_estoque
    AFTER INSERT OR UPDATE OR DELETE ON nota_peca
    FOR EACH ROW
    EXECUTE FUNCTION fn_gerenciar_estoque();


-- Recalcular valor_total da nota

CREATE OR REPLACE FUNCTION fn_recalcular_total()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_id_nota INT;
BEGIN
    v_id_nota := COALESCE(NEW.id_nota, OLD.id_nota);

    UPDATE nota
       SET valor_total = (
               SELECT COALESCE(SUM(np.valor_vendido * np.quantidade), 0.00)
                 FROM nota_peca np
                WHERE np.id_nota = v_id_nota
           )
     WHERE id_nota = v_id_nota;

    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_recalcular_total
    AFTER INSERT OR UPDATE OR DELETE ON nota_peca
    FOR EACH ROW
    EXECUTE FUNCTION fn_recalcular_total();


-- Ciclo de vida da nota


CREATE OR REPLACE FUNCTION fn_ciclo_vida_nota()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    IF NEW.status = OLD.status THEN
        NEW.valor_total := OLD.valor_total;
        NEW.data_venda  := OLD.data_venda;
        RETURN NEW;
    END IF;

    IF OLD.status IN ('Finalizado', 'Cancelado') THEN
        RAISE EXCEPTION
            'Nota % está com status "%" e não pode ser alterada.',
            OLD.id_nota, OLD.status
            USING ERRCODE = 'P0001';
    END IF;

    IF NEW.status NOT IN ('Finalizado', 'Cancelado') THEN
        RAISE EXCEPTION
            'Transição de status inválida: "%" → "%".',
            OLD.status, NEW.status
            USING ERRCODE = 'P0001';
    END IF;

    IF NEW.status = 'Finalizado' THEN
        IF NEW.forma_pagamento IS NULL THEN
            RAISE EXCEPTION
                'Informe a forma de pagamento antes de finalizar a nota %.',
                NEW.id_nota
                USING ERRCODE = 'P0001';
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM nota_peca WHERE id_nota = NEW.id_nota
        ) THEN
            RAISE EXCEPTION
                'A nota % não possui itens e não pode ser finalizada.',
                NEW.id_nota
                USING ERRCODE = 'P0001';
        END IF;

        NEW.data_venda := NOW();
    END IF;

    IF NEW.status = 'Cancelado' THEN
        -- Percorre cada item da nota, adquirindo lock individual antes
        -- de incrementar o estoque, evitando lost updates concorrentes.
        FOR r IN
            SELECT id_peca, quantidade
              FROM nota_peca
             WHERE id_nota = NEW.id_nota
        LOOP
            PERFORM quantidade FROM peca WHERE id_peca = r.id_peca FOR UPDATE;

            UPDATE peca
               SET quantidade = quantidade + r.quantidade
             WHERE id_peca = r.id_peca;
        END LOOP;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_ciclo_vida_nota
    BEFORE UPDATE ON nota
    FOR EACH ROW
    EXECUTE FUNCTION fn_ciclo_vida_nota();


-- Bloquear deleção de nota finalizada

CREATE OR REPLACE FUNCTION fn_bloquear_delete_nota()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'Finalizado' THEN
        RAISE EXCEPTION
            'Nota % está finalizada e não pode ser excluída.',
            OLD.id_nota
            USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
END;
$$;

CREATE OR REPLACE TRIGGER tg_bloquear_delete_nota
    BEFORE DELETE ON nota
    FOR EACH ROW
    EXECUTE FUNCTION fn_bloquear_delete_nota();




CREATE OR REPLACE FUNCTION fn_buscar_filial_executante(p_id_executante INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_filial INT;
BEGIN
    SELECT id_filial INTO v_filial
      FROM vendedor
     WHERE id_vendedor = p_id_executante;

    IF v_filial IS NULL THEN
        RAISE EXCEPTION 'Executante % não encontrado.', p_id_executante
            USING ERRCODE = 'P0001';
    END IF;

    RETURN v_filial;
END;
$$;


CREATE OR REPLACE FUNCTION fn_registrar_cliente(
    p_nome     VARCHAR,
    p_cpf_cnpj VARCHAR,
    p_telefone VARCHAR,
    p_email    VARCHAR
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id_cliente INT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM cliente WHERE cpf_cnpj = p_cpf_cnpj
    ) THEN
        RAISE EXCEPTION 'Cliente já cadastrado.'
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO cliente (nome, cpf_cnpj, telefone, email)
    VALUES (p_nome, p_cpf_cnpj, p_telefone, p_email)
    RETURNING id_cliente INTO v_id_cliente;

    RETURN v_id_cliente;
END;
$$;


CREATE OR REPLACE FUNCTION fn_criar_filial(
    p_nome_filial   VARCHAR,
    p_cidade        VARCHAR,
    p_endereco      VARCHAR,
    p_cnpj          VARCHAR,
    p_id_executante INT
)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT cargo FROM vendedor WHERE id_vendedor = p_id_executante) <> 'Admin' THEN
        RAISE EXCEPTION 'Apenas o Administrador pode criar novas filiais.'
            USING ERRCODE = 'P0001';
    END IF;

    IF CHAR_LENGTH(TRIM(p_cnpj)) <> 18 THEN
        RAISE EXCEPTION 'CNPJ inválido. Formato esperado: XX.XXX.XXX/XXXX-XX.'
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM filial WHERE nome_unidade = p_nome_filial) THEN
        RAISE EXCEPTION 'Já existe uma filial com o nome "%".', p_nome_filial
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM filial WHERE cnpj = p_cnpj) THEN
        RAISE EXCEPTION 'Já existe uma filial com o CNPJ "%".', p_cnpj
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO filial (nome_unidade, cidade, endereco, cnpj)
    VALUES (p_nome_filial, p_cidade, p_endereco, p_cnpj);

    RAISE NOTICE 'Nova filial "%" cadastrada com sucesso.', p_nome_filial;
END;
$$;


CREATE OR REPLACE FUNCTION fn_registrar_categoria(
    p_nova_categoria VARCHAR,
    p_id_executante  INT
)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT cargo FROM vendedor WHERE id_vendedor = p_id_executante) <> 'Admin' THEN
        RAISE EXCEPTION 'Apenas o Administrador pode criar novas categorias.'
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM categoria WHERE nome_categoria = p_nova_categoria) THEN
        RAISE EXCEPTION 'A categoria "%" já existe.', p_nova_categoria
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO categoria (nome_categoria) VALUES (p_nova_categoria);

    RAISE NOTICE 'Categoria "%" cadastrada com sucesso.', p_nova_categoria;
END;
$$;


CREATE OR REPLACE FUNCTION fn_registrar_marca(
    p_nova_marca    VARCHAR,
    p_id_executante INT
)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT cargo FROM vendedor WHERE id_vendedor = p_id_executante) <> 'Admin' THEN
        RAISE EXCEPTION 'Apenas o Administrador pode cadastrar novas marcas.'
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM marca WHERE nome_marca = p_nova_marca) THEN
        RAISE EXCEPTION 'A marca "%" já está cadastrada.', p_nova_marca
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO marca (nome_marca) VALUES (p_nova_marca);

    RAISE NOTICE 'Marca "%" cadastrada com sucesso.', p_nova_marca;
END;
$$;


CREATE OR REPLACE FUNCTION fn_registrar_modelo(
    p_nome_modelo   VARCHAR,
    p_id_marca      INT,
    p_id_executante INT
)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT cargo FROM vendedor WHERE id_vendedor = p_id_executante) <> 'Admin' THEN
        RAISE EXCEPTION 'Apenas o Administrador pode cadastrar novos modelos.'
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM marca WHERE id_marca = p_id_marca) THEN
        RAISE EXCEPTION 'Marca % não encontrada.', p_id_marca
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (
        SELECT 1 FROM modelo
         WHERE nome_modelo = p_nome_modelo
           AND id_marca    = p_id_marca
    ) THEN
        RAISE EXCEPTION 'O modelo "%" já está cadastrado para essa marca.', p_nome_modelo
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO modelo (nome_modelo, id_marca) VALUES (p_nome_modelo, p_id_marca);

    RAISE NOTICE 'Modelo "%" cadastrado com sucesso.', p_nome_modelo;
END;
$$;


CREATE OR REPLACE FUNCTION fn_registrar_peca(
    p_nome_peca          VARCHAR,
    p_valor              NUMERIC,
    p_estado_conservacao VARCHAR,
    p_quantidade         INT,
    p_id_categoria       INT,
    p_id_filial          INT,
    p_id_executante      INT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id_peca           INT;
    v_filial_executante INT;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    IF v_filial_executante <> p_id_filial THEN
        RAISE EXCEPTION 'O executante não pode cadastrar peças em outra filial.'
            USING ERRCODE = 'P0001';
    END IF;

    IF p_valor <= 0 THEN
        RAISE EXCEPTION 'O valor da peça deve ser maior que zero.'
            USING ERRCODE = 'P0001';
    END IF;

    IF p_quantidade < 0 THEN
        RAISE EXCEPTION 'A quantidade não pode ser negativa.'
            USING ERRCODE = 'P0001';
    END IF;

    IF p_estado_conservacao NOT IN ('Novo', 'Seminovo', 'Usado') THEN
        RAISE EXCEPTION 'Estado de conservação inválido: "%". Use: Novo, Seminovo ou Usado.',
            p_estado_conservacao
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM categoria WHERE id_categoria = p_id_categoria) THEN
        RAISE EXCEPTION 'Categoria % não encontrada.', p_id_categoria
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM filial WHERE id_filial = p_id_filial) THEN
        RAISE EXCEPTION 'Filial % não encontrada.', p_id_filial
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (
        SELECT 1 FROM peca
         WHERE nome_peca          = p_nome_peca
           AND estado_conservacao = p_estado_conservacao
           AND id_filial          = p_id_filial
    ) THEN
        RAISE EXCEPTION 'Já existe uma peça "%" com estado "%" cadastrada nessa filial.',
            p_nome_peca, p_estado_conservacao
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO peca (nome_peca, valor, estado_conservacao, id_categoria, id_filial, quantidade)
    VALUES (p_nome_peca, p_valor, p_estado_conservacao, p_id_categoria, p_id_filial, p_quantidade)
    RETURNING id_peca INTO v_id_peca;

    RAISE NOTICE 'Peça "%" cadastrada com sucesso. ID: %', p_nome_peca, v_id_peca;
    RETURN v_id_peca;
END;
$$;


CREATE OR REPLACE FUNCTION fn_registrar_comp_peca(
    p_id_peca       INT,
    p_id_modelo     INT,
    p_ano_inicio    SMALLINT,
    p_ano_fim       SMALLINT,
    p_id_executante INT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id_nova_comp      INT;
    v_filial_executante INT;
    v_filial_peca       INT;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    IF NOT EXISTS (SELECT 1 FROM peca WHERE id_peca = p_id_peca) THEN
        RAISE EXCEPTION 'Peça % não encontrada.', p_id_peca
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM modelo WHERE id_modelo = p_id_modelo) THEN
        RAISE EXCEPTION 'Modelo % não encontrado.', p_id_modelo
            USING ERRCODE = 'P0001';
    END IF;

    SELECT id_filial INTO v_filial_peca FROM peca WHERE id_peca = p_id_peca;

    IF v_filial_executante <> v_filial_peca THEN
        RAISE EXCEPTION 'O executante não pode alterar peças de outra filial.'
            USING ERRCODE = 'P0001';
    END IF;

    IF p_ano_inicio > p_ano_fim THEN
        RAISE EXCEPTION 'O ano de início % não pode ser maior que o ano fim %.', p_ano_inicio, p_ano_fim
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (
        SELECT 1 FROM compatibilidade
         WHERE id_peca    = p_id_peca
           AND id_modelo  = p_id_modelo
           AND ano_inicio = p_ano_inicio
           AND ano_fim    = p_ano_fim
    ) THEN
        RAISE EXCEPTION 'Compatibilidade já cadastrada para esse modelo e intervalo de anos.'
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO compatibilidade (id_peca, id_modelo, ano_inicio, ano_fim)
    VALUES (p_id_peca, p_id_modelo, p_ano_inicio, p_ano_fim)
    RETURNING id_comp INTO v_id_nova_comp;

    RAISE NOTICE 'Compatibilidade cadastrada com sucesso. ID: %', v_id_nova_comp;
    RETURN v_id_nova_comp;
END;
$$;


CREATE OR REPLACE FUNCTION fn_ajustar_estoque(
    p_id_peca_ajuste INT,
    p_qtd_nova       INT,
    p_id_executante  INT
)
RETURNS TABLE(peca_id INT, quantidade_atual INT) LANGUAGE plpgsql AS $$
DECLARE
    v_filial_executante INT;
    v_filial_peca       INT;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    IF NOT EXISTS (SELECT 1 FROM peca WHERE id_peca = p_id_peca_ajuste) THEN
        RAISE EXCEPTION 'Peça % não encontrada.', p_id_peca_ajuste
            USING ERRCODE = 'P0001';
    END IF;

    IF p_qtd_nova < 0 THEN
        RAISE EXCEPTION 'A quantidade não pode ser negativa.'
            USING ERRCODE = 'P0001';
    END IF;

    SELECT id_filial INTO v_filial_peca FROM peca WHERE id_peca = p_id_peca_ajuste;

    IF v_filial_executante <> v_filial_peca THEN
        RAISE EXCEPTION 'O executante não pode ajustar estoque de outra filial.'
            USING ERRCODE = 'P0001';
    END IF;

    RETURN QUERY
        UPDATE peca
           SET quantidade = p_qtd_nova
         WHERE id_peca = p_id_peca_ajuste
        RETURNING id_peca, quantidade;
END;
$$;


CREATE OR REPLACE FUNCTION fn_contratar_vendedor(
    p_nome          VARCHAR,
    p_cpf           VARCHAR,
    p_id_filial     INT,
    p_id_executante INT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id_vendedor_novo  INT;
    v_filial_executante INT;
    v_cargo_executante  VARCHAR;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    SELECT cargo INTO v_cargo_executante FROM vendedor WHERE id_vendedor = p_id_executante;
    IF v_cargo_executante NOT IN ('Gerente', 'Admin') THEN
        RAISE EXCEPTION 'Apenas Gerente ou Administrador podem contratar vendedores.'
            USING ERRCODE = 'P0001';
    END IF;

    IF v_cargo_executante = 'Gerente' AND v_filial_executante <> p_id_filial THEN
        RAISE EXCEPTION 'O Gerente só pode contratar vendedores para a própria filial.'
            USING ERRCODE = 'P0001';
    END IF;

    IF CHAR_LENGTH(TRIM(p_cpf)) <> 14 THEN
        RAISE EXCEPTION 'CPF inválido. Formato esperado: XXX.XXX.XXX-XX.'
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM vendedor WHERE cpf = p_cpf) THEN
        RAISE EXCEPTION 'Já existe um vendedor com o CPF "%".', p_cpf
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM filial WHERE id_filial = p_id_filial) THEN
        RAISE EXCEPTION 'Filial % não encontrada.', p_id_filial
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO vendedor (nome, cpf, id_filial, ativo, cargo)
    VALUES (p_nome, p_cpf, p_id_filial, TRUE, 'Vendedor')
    RETURNING id_vendedor INTO v_id_vendedor_novo;

    RAISE NOTICE 'Vendedor "%" contratado com sucesso. ID: %', p_nome, v_id_vendedor_novo;
    RETURN v_id_vendedor_novo;
END;
$$;


CREATE OR REPLACE FUNCTION fn_demitir_vendedor(
    p_cpf_dem       VARCHAR,
    p_id_executante INT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id_vendedor_dem   INT;
    v_filial_dem        INT;
    v_filial_executante INT;
    v_cargo_executante  VARCHAR;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    SELECT cargo INTO v_cargo_executante FROM vendedor WHERE id_vendedor = p_id_executante;
    IF v_cargo_executante NOT IN ('Gerente', 'Admin') THEN
        RAISE EXCEPTION 'Apenas Gerente ou Administrador podem demitir vendedores.'
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM vendedor WHERE cpf = p_cpf_dem) THEN
        RAISE EXCEPTION 'Vendedor com CPF "%" não encontrado.', p_cpf_dem
            USING ERRCODE = 'P0001';
    END IF;

    SELECT id_vendedor, id_filial INTO v_id_vendedor_dem, v_filial_dem
      FROM vendedor WHERE cpf = p_cpf_dem;

    IF v_cargo_executante = 'Gerente' AND v_filial_executante <> v_filial_dem THEN
        RAISE EXCEPTION 'O Gerente só pode demitir vendedores da própria filial.'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE vendedor SET ativo = FALSE WHERE id_vendedor = v_id_vendedor_dem;

    RAISE NOTICE 'Vendedor de ID % desativado com sucesso.', v_id_vendedor_dem;
    RETURN v_id_vendedor_dem;
END;
$$;


CREATE OR REPLACE FUNCTION fn_transferir_vendedor(
    p_cpf_vendedor   VARCHAR,
    p_id_filial_org  INT,
    p_id_filial_dest INT,
    p_id_executante  INT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id_vendedor_trans INT;
    v_filial_executante INT;
    v_cargo_executante  VARCHAR;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    SELECT cargo INTO v_cargo_executante FROM vendedor WHERE id_vendedor = p_id_executante;
    IF v_cargo_executante NOT IN ('Gerente', 'Admin') THEN
        RAISE EXCEPTION 'Apenas Gerente ou Administrador podem transferir vendedores.'
            USING ERRCODE = 'P0001';
    END IF;

    IF p_id_filial_org = p_id_filial_dest THEN
        RAISE EXCEPTION 'As filiais de origem e destino não podem ser iguais.'
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM filial WHERE id_filial = p_id_filial_org) THEN
        RAISE EXCEPTION 'Filial de origem % não encontrada.', p_id_filial_org
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM filial WHERE id_filial = p_id_filial_dest) THEN
        RAISE EXCEPTION 'Filial de destino % não encontrada.', p_id_filial_dest
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM vendedor
         WHERE cpf = p_cpf_vendedor AND id_filial = p_id_filial_org
    ) THEN
        RAISE EXCEPTION 'Vendedor com CPF "%" não encontrado na filial de origem %.',
            p_cpf_vendedor, p_id_filial_org
            USING ERRCODE = 'P0001';
    END IF;

    IF v_cargo_executante = 'Gerente' AND v_filial_executante <> p_id_filial_org THEN
        RAISE EXCEPTION 'O Gerente só pode transferir vendedores da própria filial.'
            USING ERRCODE = 'P0001';
    END IF;

    SELECT id_vendedor INTO v_id_vendedor_trans FROM vendedor WHERE cpf = p_cpf_vendedor;

    IF EXISTS (
        SELECT 1 FROM nota
         WHERE id_vendedor = v_id_vendedor_trans AND status = 'Aberto'
    ) THEN
        RAISE EXCEPTION 'O vendedor possui notas em aberto e não pode ser transferido.'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE vendedor SET id_filial = p_id_filial_dest WHERE id_vendedor = v_id_vendedor_trans;

    RAISE NOTICE 'Vendedor de ID % transferido para a filial % com sucesso.',
        v_id_vendedor_trans, p_id_filial_dest;
    RETURN v_id_vendedor_trans;
END;
$$;


CREATE OR REPLACE FUNCTION fn_abrir_nota(
    p_id_cliente    INT,
    p_id_vendedor   INT,
    p_id_executante INT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id_nova_nota      INT;
    v_filial_executante INT;
    v_filial_vendedor   INT;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    IF NOT EXISTS (SELECT 1 FROM vendedor WHERE id_vendedor = p_id_vendedor) THEN
        RAISE EXCEPTION 'Vendedor % não encontrado.', p_id_vendedor
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cliente WHERE id_cliente = p_id_cliente) THEN
        RAISE EXCEPTION 'Cliente % não encontrado.', p_id_cliente
            USING ERRCODE = 'P0001';
    END IF;

    SELECT id_filial INTO v_filial_vendedor FROM vendedor WHERE id_vendedor = p_id_vendedor;
    IF v_filial_executante <> v_filial_vendedor THEN
        RAISE EXCEPTION 'O executante não pode abrir notas para vendedores de outra filial.'
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO nota (id_cliente, id_vendedor)
    VALUES (p_id_cliente, p_id_vendedor)
    RETURNING id_nota INTO v_id_nova_nota;

    RAISE NOTICE 'Nota % criada com sucesso.', v_id_nova_nota;
    RETURN v_id_nova_nota;
END;
$$;


CREATE OR REPLACE FUNCTION fn_adicionar_item_nota(
    p_id_nota       INT,
    p_id_peca       INT,
    p_quantidade    INT,
    p_valor_vendido NUMERIC
)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM nota WHERE id_nota = p_id_nota) THEN
        RAISE EXCEPTION 'Nota % não encontrada.', p_id_nota
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM peca WHERE id_peca = p_id_peca) THEN
        RAISE EXCEPTION 'Peça % não encontrada.', p_id_peca
            USING ERRCODE = 'P0001';
    END IF;

    IF p_quantidade <= 0 THEN
        RAISE EXCEPTION 'A quantidade deve ser maior que zero.'
            USING ERRCODE = 'P0001';
    END IF;

    IF p_valor_vendido <= 0 THEN
        RAISE EXCEPTION 'O valor vendido deve ser maior que zero.'
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO nota_peca (id_nota, id_peca, valor_vendido, quantidade)
    VALUES (p_id_nota, p_id_peca, p_valor_vendido, p_quantidade);

    RAISE NOTICE 'Peça % adicionada à nota % com sucesso.', p_id_peca, p_id_nota;
END;
$$;


CREATE OR REPLACE FUNCTION fn_finalizar_nota(
    p_id_nota         INT,
    p_forma_pagamento VARCHAR,
    p_id_executante   INT
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_filial_vendedor   INT;
    v_id_vendedor       INT;
    v_filial_executante INT;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    IF NOT EXISTS (SELECT 1 FROM nota WHERE id_nota = p_id_nota) THEN
        RAISE EXCEPTION 'Nota % não encontrada.', p_id_nota
            USING ERRCODE = 'P0001';
    END IF;

    IF p_forma_pagamento NOT IN ('Pix', 'Dinheiro', 'Cartão de Crédito', 'Cartão de Débito', 'Boleto') THEN
        RAISE EXCEPTION 'Forma de pagamento inválida: "%". Use: Pix, Dinheiro, Cartão de Crédito, Cartão de Débito ou Boleto.',
            p_forma_pagamento
            USING ERRCODE = 'P0001';
    END IF;

    SELECT id_vendedor INTO v_id_vendedor FROM nota WHERE id_nota = p_id_nota;
    SELECT id_filial INTO v_filial_vendedor FROM vendedor WHERE id_vendedor = v_id_vendedor;

    IF v_filial_executante <> v_filial_vendedor THEN
        RAISE EXCEPTION 'O executante não pode finalizar notas de vendedores de outra filial.'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE nota
       SET forma_pagamento = p_forma_pagamento,
           status          = 'Finalizado'
     WHERE id_nota = p_id_nota;

    RAISE NOTICE 'Nota % finalizada - Pagamento: %.', p_id_nota, p_forma_pagamento;
END;
$$;


CREATE OR REPLACE FUNCTION fn_cancelar_nota(
    p_id_nota       INT,
    p_id_executante INT
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_filial_vendedor   INT;
    v_filial_executante INT;
    v_id_vendedor       INT;
BEGIN
    v_filial_executante := fn_buscar_filial_executante(p_id_executante);

    IF NOT EXISTS (SELECT 1 FROM nota WHERE id_nota = p_id_nota) THEN
        RAISE EXCEPTION 'Nota % não encontrada.', p_id_nota
            USING ERRCODE = 'P0001';
    END IF;

    SELECT id_vendedor INTO v_id_vendedor FROM nota WHERE id_nota = p_id_nota;
    SELECT id_filial INTO v_filial_vendedor FROM vendedor WHERE id_vendedor = v_id_vendedor;

    IF v_filial_executante <> v_filial_vendedor THEN
        RAISE EXCEPTION 'O executante não pode cancelar notas de vendedores de outra filial.'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE nota SET status = 'Cancelado' WHERE id_nota = p_id_nota;

    RAISE NOTICE 'Nota % cancelada.', p_id_nota;
END;
$$;




CREATE OR REPLACE VIEW vw_estoque_filial AS
SELECT
    f.id_filial,
    f.nome_unidade                  AS filial,
    f.cidade,
    p.id_peca,
    p.nome_peca                     AS peca,
    cat.nome_categoria              AS categoria,
    p.estado_conservacao,
    p.quantidade,
    p.valor
FROM peca p
JOIN filial    f   ON f.id_filial     = p.id_filial
JOIN categoria cat ON cat.id_categoria = p.id_categoria
ORDER BY f.nome_unidade, cat.nome_categoria, p.nome_peca;


CREATE OR REPLACE VIEW vw_historico_cliente AS
SELECT
    cl.id_cliente,
    cl.nome                                    AS cliente,
    n.id_nota,
    n.data_venda,
    n.forma_pagamento,
    n.valor_total,
    p.id_peca,
    p.nome_peca                                AS peca,
    p.estado_conservacao,
    np.quantidade,
    np.valor_vendido,
    (np.quantidade * np.valor_vendido)         AS subtotal
FROM nota n
JOIN cliente   cl ON cl.id_cliente = n.id_cliente
JOIN nota_peca np ON np.id_nota    = n.id_nota
JOIN peca       p ON p.id_peca     = np.id_peca
WHERE n.status = 'Finalizado'
ORDER BY cl.nome, n.data_venda DESC;


CREATE OR REPLACE VIEW vw_compatibilidade_pecas AS
SELECT
    f.nome_unidade                  AS filial,
    ma.nome_marca                   AS marca,
    mo.nome_modelo                  AS modelo,
    c.ano_inicio,
    c.ano_fim,
    p.id_peca,
    p.nome_peca                     AS peca,
    p.estado_conservacao,
    p.quantidade,
    p.valor,
    cat.nome_categoria              AS categoria
FROM compatibilidade c
JOIN peca      p   ON p.id_peca       = c.id_peca
JOIN modelo    mo  ON mo.id_modelo    = c.id_modelo
JOIN marca     ma  ON ma.id_marca     = mo.id_marca
JOIN categoria cat ON cat.id_categoria = p.id_categoria
JOIN filial    f   ON f.id_filial     = p.id_filial
ORDER BY ma.nome_marca, mo.nome_modelo, c.ano_inicio, p.nome_peca;


CREATE OR REPLACE VIEW vw_notas_abertas AS
SELECT
    n.id_nota,
    n.data_criacao,
    f.nome_unidade                                     AS filial,
    v.nome                                             AS vendedor,
    cl.nome                                            AS cliente,
    cl.telefone,
    COUNT(np.id_peca)                                  AS total_itens,
    COALESCE(SUM(np.quantidade * np.valor_vendido), 0) AS valor_parcial
FROM nota n
JOIN vendedor  v  ON v.id_vendedor = n.id_vendedor
JOIN filial    f  ON f.id_filial   = v.id_filial
JOIN cliente   cl ON cl.id_cliente = n.id_cliente
LEFT JOIN nota_peca np ON np.id_nota = n.id_nota
WHERE n.status = 'Aberto'
GROUP BY
    n.id_nota, n.data_criacao,
    f.nome_unidade,
    v.nome,
    cl.nome, cl.telefone
ORDER BY n.data_criacao;


CREATE OR REPLACE VIEW vw_estoque_baixo AS
SELECT
    f.id_filial,
    f.nome_unidade                  AS filial,
    f.cidade,
    p.id_peca,
    p.nome_peca                     AS peca,
    cat.nome_categoria              AS categoria,
    p.estado_conservacao,
    p.quantidade,
    p.valor
FROM peca p
JOIN filial    f   ON f.id_filial     = p.id_filial
JOIN categoria cat ON cat.id_categoria = p.id_categoria
WHERE p.quantidade <= 1
ORDER BY f.nome_unidade, p.quantidade, p.nome_peca;


-- CORREÇÃO 3: Subconsulta de peca_mais_vendida corrigida.
-- Substituído MIN(n.data_venda) por DATE_TRUNC('month', n.data_venda),
-- garantindo que a peça mais vendida seja calculada para o período correto
-- de cada linha do GROUP BY, e não sempre o primeiro mês do grupo.
CREATE OR REPLACE VIEW vw_resumo_vendas_filial AS
SELECT
    f.id_filial,
    f.nome_unidade                          AS filial,
    DATE_TRUNC('month', n.data_venda)       AS periodo,
    COUNT(DISTINCT n.id_nota)               AS total_notas,
    SUM(n.valor_total)                      AS faturamento,
    ROUND(AVG(n.valor_total), 2)            AS ticket_medio,
    top_peca.nome_peca                      AS peca_mais_vendida
FROM nota n
JOIN vendedor v ON v.id_vendedor = n.id_vendedor
JOIN filial   f ON f.id_filial   = v.id_filial
LEFT JOIN LATERAL (
    SELECT p2.nome_peca
    FROM nota_peca np2
    JOIN nota  n2 ON n2.id_nota = np2.id_nota
    JOIN peca  p2 ON p2.id_peca = np2.id_peca
    WHERE n2.status = 'Finalizado'
      AND p2.id_filial = f.id_filial
      AND DATE_TRUNC('month', n2.data_venda) = DATE_TRUNC('month', n.data_venda)
    GROUP BY p2.nome_peca
    ORDER BY SUM(np2.quantidade) DESC
    LIMIT 1
) top_peca ON TRUE
WHERE n.status = 'Finalizado'
GROUP BY f.id_filial, f.nome_unidade, DATE_TRUNC('month', n.data_venda), top_peca.nome_peca
ORDER BY f.nome_unidade, periodo DESC;


CREATE OR REPLACE VIEW vw_desempenho_vendedores AS
SELECT
    f.id_filial,
    f.nome_unidade                            AS filial,
    v.id_vendedor,
    v.nome                                    AS vendedor,
    v.cargo,
    v.ativo,
    COUNT(DISTINCT n.id_nota)                 AS total_notas,
    COALESCE(SUM(n.valor_total), 0)           AS faturamento_total,
    COALESCE(ROUND(AVG(n.valor_total), 2), 0) AS ticket_medio,
    RANK() OVER (
        PARTITION BY f.id_filial
        ORDER BY COALESCE(SUM(n.valor_total), 0) DESC
    )                                         AS ranking_filial
FROM vendedor v
JOIN filial f ON f.id_filial = v.id_filial
LEFT JOIN nota n ON n.id_vendedor = v.id_vendedor AND n.status = 'Finalizado'
GROUP BY f.id_filial, f.nome_unidade, v.id_vendedor, v.nome, v.cargo, v.ativo
ORDER BY f.nome_unidade, ranking_filial;


CREATE OR REPLACE VIEW vw_faturamento_categoria AS
SELECT
    f.id_filial,
    f.nome_unidade                          AS filial,
    cat.id_categoria,
    cat.nome_categoria                      AS categoria,
    COUNT(DISTINCT np.id_peca)              AS total_skus_vendidos,
    SUM(np.quantidade)                      AS unidades_vendidas,
    SUM(np.quantidade * np.valor_vendido)   AS faturamento_total,
    ROUND(AVG(np.valor_vendido), 2)         AS preco_medio_vendido
FROM nota_peca np
JOIN nota      n   ON n.id_nota       = np.id_nota
JOIN peca      p   ON p.id_peca       = np.id_peca
JOIN categoria cat ON cat.id_categoria = p.id_categoria
JOIN vendedor  v   ON v.id_vendedor   = n.id_vendedor
JOIN filial    f   ON f.id_filial     = v.id_filial
WHERE n.status = 'Finalizado'
GROUP BY f.id_filial, f.nome_unidade, cat.id_categoria, cat.nome_categoria
ORDER BY f.nome_unidade, faturamento_total DESC;


CREATE OR REPLACE VIEW vw_pecas_mais_vendidas AS
SELECT
    f.id_filial,
    f.nome_unidade                          AS filial,
    p.id_peca,
    p.nome_peca                             AS peca,
    cat.nome_categoria                      AS categoria,
    p.estado_conservacao,
    SUM(np.quantidade)                      AS unidades_vendidas,
    SUM(np.quantidade * np.valor_vendido)   AS faturamento_total,
    RANK() OVER (
        PARTITION BY f.id_filial
        ORDER BY SUM(np.quantidade) DESC
    )                                       AS ranking_filial
FROM nota_peca np
JOIN nota      n   ON n.id_nota       = np.id_nota
JOIN peca      p   ON p.id_peca       = np.id_peca
JOIN categoria cat ON cat.id_categoria = p.id_categoria
JOIN vendedor  v   ON v.id_vendedor   = n.id_vendedor
JOIN filial    f   ON f.id_filial     = v.id_filial
WHERE n.status = 'Finalizado'
GROUP BY f.id_filial, f.nome_unidade, p.id_peca, p.nome_peca, cat.nome_categoria, p.estado_conservacao
ORDER BY f.nome_unidade, ranking_filial;


CREATE OR REPLACE VIEW vw_historico_vendas_vendedor AS
SELECT
    v.id_vendedor,
    v.nome                          AS vendedor,
    v.cargo,
    f.nome_unidade                  AS filial,
    n.id_nota,
    n.data_venda,
    n.forma_pagamento,
    cl.nome                         AS cliente,
    n.valor_total,
    COUNT(np.id_peca)               AS total_itens
FROM nota n
JOIN vendedor  v  ON v.id_vendedor = n.id_vendedor
JOIN filial    f  ON f.id_filial   = v.id_filial
JOIN cliente   cl ON cl.id_cliente = n.id_cliente
JOIN nota_peca np ON np.id_nota    = n.id_nota
WHERE n.status = 'Finalizado'
GROUP BY
    v.id_vendedor, v.nome, v.cargo,
    f.nome_unidade,
    n.id_nota, n.data_venda, n.forma_pagamento,
    cl.nome, n.valor_total
ORDER BY v.nome, n.data_venda DESC;


CREATE OR REPLACE VIEW vw_clientes_frequentes AS
SELECT
    cl.id_cliente,
    cl.nome                          AS cliente,
    cl.telefone,
    cl.email,
    COUNT(DISTINCT n.id_nota)        AS total_compras,
    SUM(n.valor_total)               AS gasto_total,
    ROUND(AVG(n.valor_total), 2)     AS ticket_medio,
    MAX(n.data_venda)                AS ultima_compra
FROM cliente cl
JOIN nota n ON n.id_cliente = cl.id_cliente
WHERE n.status = 'Finalizado'
GROUP BY cl.id_cliente, cl.nome, cl.telefone, cl.email
ORDER BY gasto_total DESC;


CREATE OR REPLACE VIEW vw_auditoria_notas AS
SELECT
    n.id_nota,
    n.data_criacao,
    n.data_venda,
    n.status,
    n.forma_pagamento,
    n.valor_total,
    f.id_filial,
    f.nome_unidade                  AS filial,
    v.id_vendedor,
    v.nome                          AS vendedor,
    v.cargo,
    cl.id_cliente,
    cl.nome                         AS cliente,
    COUNT(np.id_peca)               AS total_itens
FROM nota n
JOIN vendedor  v  ON v.id_vendedor  = n.id_vendedor
JOIN filial    f  ON f.id_filial    = v.id_filial
JOIN cliente   cl ON cl.id_cliente  = n.id_cliente
LEFT JOIN nota_peca np ON np.id_nota = n.id_nota
GROUP BY
    n.id_nota, n.data_criacao, n.data_venda, n.status,
    n.forma_pagamento, n.valor_total,
    f.id_filial, f.nome_unidade,
    v.id_vendedor, v.nome, v.cargo,
    cl.id_cliente, cl.nome
ORDER BY n.data_criacao DESC;


CREATE OR REPLACE VIEW vw_resumo_global AS
SELECT
    f.id_filial,
    f.nome_unidade                              AS filial,
    f.cidade,
    COUNT(DISTINCT p.id_peca)                   AS total_skus,
    COALESCE(SUM(p.quantidade), 0)              AS total_unidades_estoque,
    COALESCE(SUM(p.quantidade * p.valor), 0)    AS valor_estoque,
    COUNT(DISTINCT n.id_nota)                   AS total_notas_finalizadas,
    COALESCE(SUM(n.valor_total), 0)             AS faturamento_total,
    COALESCE(ROUND(AVG(n.valor_total), 2), 0)   AS ticket_medio,
    COUNT(DISTINCT v.id_vendedor)               AS total_vendedores,
    COUNT(DISTINCT v.id_vendedor)
        FILTER (WHERE v.ativo = TRUE)           AS vendedores_ativos
FROM filial f
LEFT JOIN peca     p ON p.id_filial   = f.id_filial
LEFT JOIN vendedor v ON v.id_filial   = f.id_filial
LEFT JOIN nota     n ON n.id_vendedor = v.id_vendedor
                    AND n.status      = 'Finalizado'
GROUP BY f.id_filial, f.nome_unidade, f.cidade
ORDER BY faturamento_total DESC;



CREATE ROLE role_vendedor;
CREATE ROLE role_gerente;
CREATE ROLE role_admin;

-- Tabelas de catálogo (leitura pública)
GRANT SELECT ON marca           TO role_vendedor;
GRANT SELECT ON modelo          TO role_vendedor;
GRANT SELECT ON categoria       TO role_vendedor;
GRANT SELECT ON filial          TO role_vendedor;
GRANT SELECT ON cliente         TO role_vendedor;

-- Tabelas operacionais (leitura para triggers funcionarem via funções)
GRANT SELECT ON peca            TO role_vendedor;
GRANT SELECT ON compatibilidade TO role_vendedor;
GRANT SELECT ON nota            TO role_vendedor;
GRANT SELECT ON nota_peca       TO role_vendedor;

-- Sequences
GRANT USAGE ON SEQUENCE cliente_id_cliente_seq       TO role_vendedor;
GRANT USAGE ON SEQUENCE peca_id_peca_seq             TO role_vendedor;
GRANT USAGE ON SEQUENCE compatibilidade_id_comp_seq  TO role_vendedor;
GRANT USAGE ON SEQUENCE nota_id_nota_seq             TO role_vendedor;

-- Views do vendedor
GRANT SELECT ON vw_estoque_filial        TO role_vendedor;
GRANT SELECT ON vw_historico_cliente     TO role_vendedor;
GRANT SELECT ON vw_compatibilidade_pecas TO role_vendedor;
GRANT SELECT ON vw_notas_abertas         TO role_vendedor;
GRANT SELECT ON vw_estoque_baixo         TO role_vendedor;

-- Funções do vendedor
GRANT EXECUTE ON FUNCTION fn_registrar_cliente(VARCHAR, VARCHAR, VARCHAR, VARCHAR)          TO role_vendedor;
GRANT EXECUTE ON FUNCTION fn_registrar_peca(VARCHAR, NUMERIC, VARCHAR, INT, INT, INT, INT)  TO role_vendedor;
GRANT EXECUTE ON FUNCTION fn_registrar_comp_peca(INT, INT, SMALLINT, SMALLINT, INT)         TO role_vendedor;
GRANT EXECUTE ON FUNCTION fn_ajustar_estoque(INT, INT, INT)                                 TO role_vendedor;
GRANT EXECUTE ON FUNCTION fn_abrir_nota(INT, INT, INT)                                      TO role_vendedor;
GRANT EXECUTE ON FUNCTION fn_adicionar_item_nota(INT, INT, INT, NUMERIC)                    TO role_vendedor;
GRANT EXECUTE ON FUNCTION fn_finalizar_nota(INT, VARCHAR, INT)                              TO role_vendedor;
GRANT EXECUTE ON FUNCTION fn_cancelar_nota(INT, INT)                                        TO role_vendedor;


-- Gerente herda tudo do vendedor
GRANT role_vendedor TO role_gerente;

GRANT USAGE ON SEQUENCE vendedor_id_vendedor_seq TO role_gerente;

-- Views adicionais do gerente
GRANT SELECT ON vw_resumo_vendas_filial      TO role_gerente;
GRANT SELECT ON vw_desempenho_vendedores     TO role_gerente;
GRANT SELECT ON vw_faturamento_categoria     TO role_gerente;
GRANT SELECT ON vw_pecas_mais_vendidas       TO role_gerente;
GRANT SELECT ON vw_historico_vendas_vendedor TO role_gerente;
GRANT SELECT ON vw_clientes_frequentes       TO role_gerente;

-- Funções adicionais do gerente
GRANT EXECUTE ON FUNCTION fn_contratar_vendedor(VARCHAR, VARCHAR, INT, INT)  TO role_gerente;
GRANT EXECUTE ON FUNCTION fn_demitir_vendedor(VARCHAR, INT)                  TO role_gerente;
GRANT EXECUTE ON FUNCTION fn_transferir_vendedor(VARCHAR, INT, INT, INT)     TO role_gerente;


-- Admin herda tudo do gerente
GRANT role_gerente TO role_admin;

GRANT USAGE ON SEQUENCE filial_id_filial_seq      TO role_admin;
GRANT USAGE ON SEQUENCE marca_id_marca_seq         TO role_admin;
GRANT USAGE ON SEQUENCE modelo_id_modelo_seq       TO role_admin;
GRANT USAGE ON SEQUENCE categoria_id_categoria_seq TO role_admin;

-- Views adicionais do admin
GRANT SELECT ON vw_auditoria_notas TO role_admin;
GRANT SELECT ON vw_resumo_global   TO role_admin;

-- Funções adicionais do admin
GRANT EXECUTE ON FUNCTION fn_criar_filial(VARCHAR, VARCHAR, VARCHAR, VARCHAR, INT) TO role_admin;
GRANT EXECUTE ON FUNCTION fn_registrar_categoria(VARCHAR, INT)                     TO role_admin;
GRANT EXECUTE ON FUNCTION fn_registrar_marca(VARCHAR, INT)                         TO role_admin;
GRANT EXECUTE ON FUNCTION fn_registrar_modelo(VARCHAR, INT, INT)                   TO role_admin;



-- USUÁRIOS


CREATE USER usr_vendedor WITH PASSWORD 'trocar_em_producao';
CREATE USER usr_gerente  WITH PASSWORD 'trocar_em_producao';
CREATE USER usr_admin    WITH PASSWORD 'trocar_em_producao';

GRANT role_vendedor TO usr_vendedor;
GRANT role_gerente  TO usr_gerente;
GRANT role_admin    TO usr_admin;
