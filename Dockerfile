# Use pgvector
FROM pgvector/pgvector:pg16
# Switch to root to install system packages
USER root

# Install Python3, pip, venv, PostgreSQL Python extension, and other dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    postgresql-plpython3-16 \
    pgcli \
    pspg \
    git

# Create a virtual environment
RUN python3 -m venv /opt/venv

# Activate the virtual environment and install the OpenAI package with a specific version
RUN . /opt/venv/bin/activate && \
    pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir openai==1.3.5 typing-extensions==4.7.1 && pip install --no-cache-dir sentence-transformers

ENV PYTHONPATH=/opt/venv/lib/python3.11/site-packages



# Create a wrapper script to run Python with the virtual environment
RUN echo '#!/bin/bash\n/opt/venv/bin/python "$@"' > /usr/local/bin/venv-python && \
    chmod +x /usr/local/bin/venv-python

# Make sure the postgres user can access the virtual environment
RUN chown -R postgres:postgres /opt/venv

RUN echo "plpython3.use_python = '/opt/venv/bin/python'" >> /usr/share/postgresql/16/postgresql.conf.sample

# Switch back to postgres user
USER postgres

# Copy the SQL file to initialize the database
COPY init.sql /docker-entrypoint-initdb.d/

# Expose the default PostgreSQL port
EXPOSE 5432





