# P4TV Docker Image - Multi-stage build
# Verifies P4 programs against P4LTL temporal properties

# Pin specific commits for reproducibility
ARG TRANSLATOR_REPO=https://github.com/NV-ThuFV/P4LTL-Translator.git
ARG TRANSLATOR_BRANCH=CPI
ARG TRANSLATOR_COMMIT=47c7cd21278e410e76f35d6e65026d5a51af2499
ARG VALIDATOR_REPO=https://github.com/NV-ThuFV/P4LTL-Validator.git
ARG VALIDATOR_COMMIT=4c82b3b562c27e61783c7b23f3ef785cd01aa25b

#############################################
# Stage 1: Build P4LTL-Translator (p4c-based)
#############################################
FROM ubuntu:20.04 AS translator-builder

ARG TRANSLATOR_REPO
ARG TRANSLATOR_BRANCH
ARG TRANSLATOR_COMMIT

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Install build dependencies
RUN apt-get update && apt-get install -y \
    cmake g++ git automake libtool libgc-dev bison flex libfl-dev \
    libgmp-dev libboost-dev libboost-iostreams-dev libboost-graph-dev \
    llvm pkg-config python2 python3 python3-pip tcpdump wget \
    autoconf libboost-filesystem-dev libboost-system-dev \
    && pip3 install scapy ply \
    && rm -rf /var/lib/apt/lists/*

# Install protobuf 3.6.1 from source
WORKDIR /tmp
RUN git clone --depth 1 --branch v3.6.1 https://github.com/protocolbuffers/protobuf.git \
    && cd protobuf \
    && git submodule update --init --recursive \
    && ./autogen.sh \
    && ./configure \
    && make -j$(nproc) \
    && make install \
    && ldconfig \
    && cd .. && rm -rf protobuf

# Clone and build P4LTL-Translator at specific branch/commit
WORKDIR /
RUN git clone --recursive --branch ${TRANSLATOR_BRANCH} ${TRANSLATOR_REPO} /p4ltl-translator \
    && cd /p4ltl-translator \
    && git checkout ${TRANSLATOR_COMMIT} \
    && git submodule update --init --recursive

WORKDIR /p4ltl-translator
RUN mkdir -p build && cd build \
    && cmake .. \
    && make -j$(nproc)

#############################################
# Stage 2: Build P4LTL-Validator (Ultimate)
#############################################
FROM ubuntu:20.04 AS validator-builder

ARG VALIDATOR_REPO
ARG VALIDATOR_COMMIT

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Install Java, Maven, zip and unzip (needed for makeP4LTL.sh)
RUN apt-get update && apt-get install -y \
    openjdk-11-jdk maven git zip unzip \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

# Clone P4LTL-Validator at specific commit
RUN git clone ${VALIDATOR_REPO} /p4ltl-validator \
    && cd /p4ltl-validator \
    && git checkout ${VALIDATOR_COMMIT}

WORKDIR /p4ltl-validator

# Patch Maven config to use official Eclipse mirrors instead of Freiburg proxy
# Eclipse 4.17 = Eclipse 2020-09 release
RUN find trunk/source -name "pom.xml" -o -name "*.target" | xargs sed -i \
    -e 's|https://monteverdi.informatik.uni-freiburg.de/nexus/content/repositories/eclipse-4.17/|https://download.eclipse.org/releases/2020-09/|g' \
    -e 's|https://monteverdi.informatik.uni-freiburg.de/nexus/content/repositories/cdt-10.0/|https://download.eclipse.org/tools/cdt/releases/10.0/|g' \
    -e 's|https://monteverdi.informatik.uni-freiburg.de/nexus/content/repositories/orbit-R20200831200620/|https://download.eclipse.org/tools/orbit/downloads/drops/R20200831200620/repository/|g'

# Build with Maven
RUN cd trunk/source/BA_MavenParentUltimate \
    && mvn clean install -Pmaterialize -DskipTests -q

# Create the P4LTL release package (script removes dir after zipping, so unzip it)
RUN cd releaseScripts/default \
    && chmod +x makeP4LTL.sh makeSettings.sh \
    && ./makeP4LTL.sh linux \
    && unzip -q P4LTL-linux.zip

#############################################
# Stage 3: Runtime Image
#############################################
FROM ubuntu:20.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    openjdk-11-jre-headless \
    libgc1c2 libgmp10 libboost-iostreams1.71.0 libboost-graph1.71.0 \
    python3 time jq cpp \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

# Create working directories
RUN mkdir -p /p4tv/bin /p4tv/validator /input /output

# Copy P4LTL-Translator binary
COPY --from=translator-builder /p4ltl-translator/build/p4c-translator /p4tv/bin/
COPY --from=translator-builder /p4ltl-translator/p4include /p4tv/p4include

# Copy P4LTL-Validator release
COPY --from=validator-builder /p4ltl-validator/releaseScripts/default/UP4LTL-linux /p4tv/validator/

# Make scripts executable
RUN chmod +x /p4tv/validator/*.sh /p4tv/validator/z3 /p4tv/validator/cvc4 \
    /p4tv/validator/cvc4nyu /p4tv/validator/mathsat /p4tv/validator/ltl2ba \
    /p4tv/bin/p4c-translator

# Setup PATH
ENV PATH="/p4tv/bin:/p4tv/validator:${PATH}"
ENV P4C_16_INCLUDE_PATH=/p4tv/p4include

# Copy entrypoint
COPY entrypoint.py /p4tv/entrypoint.py
RUN chmod +x /p4tv/entrypoint.py

WORKDIR /input

ENTRYPOINT ["/p4tv/entrypoint.py"]
