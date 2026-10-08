/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
 *
 * dce-rm-deinit-replay: send the display guest's RM shutdown RPC from the host.
 *
 * When the display guest dies without running RmShutdownAdapter, DCE RM stays
 * initialized and the next guest's DCE_RM_INIT(bInit=1) fails. This opens
 * /dev/dce-host and writes one struct dce_host_msg whose tx frame is the
 * DCE_RM_INIT(bInit=0) RPC, laid out as the guest's RM builds it
 * (rpcWriteCommonHeader + rpcDceRmInit_dce in dce_client_rpc.c). Like the
 * guest, request and response share one buffer.
 *
 * Prints the proxy return code and the RPC's rpc_result; exits 0 only if both
 * are zero. Bench tool for deciding whether the proxy can replay the
 * deinit itself on close().
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* dce-host-proxy.h is written for the kernel; supply its integer types. */
typedef uint8_t u8;
typedef uint32_t u32;
typedef int32_t s32;
#include "dce-host-proxy.h"

#define DCE_DEFAULT_DEVICE		"/dev/dce-host"
#define DCE_CLIENT_IPC_TYPE_CPU_RM	0U

/* rpc_global_enums.h, NV_VGPU_MSG_FUNCTION_DCE_RM_INIT */
#define RPC_FUNCTION_DCE_RM_INIT	168U
/* rpc_headers.h: version 3.0, NV_VGPU_MSG_SIGNATURE_VALID, RESULT_RPC_PENDING */
#define RPC_HEADER_VERSION		0x03000000U
#define RPC_SIGNATURE_VALID		0x43505256U
#define RPC_RESULT_PENDING		0xFFFFFFFFU

/* g_rpc-message-header.h rpc_message_header_v03_00, then g_rpc-structures.h
 * rpc_dce_rm_init_v01_00. */
struct rpc_dce_rm_init {
	uint32_t header_version;
	uint32_t signature;
	uint32_t length;
	uint32_t function;
	uint32_t rpc_result;
	uint32_t rpc_result_private;
	uint32_t sequence;
	uint32_t spare;
	uint32_t bInit;
};

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : DCE_DEFAULT_DEVICE;
	struct rpc_dce_rm_init frame;
	struct dce_host_msg msg;
	ssize_t written;
	int fd;

	if (argc > 2 || (argc == 2 && argv[1][0] == '-')) {
		fprintf(stderr, "usage: %s [device]\n", argv[0]);
		return 2;
	}

	memset(&frame, 0, sizeof(frame));
	frame.header_version = RPC_HEADER_VERSION;
	frame.signature = RPC_SIGNATURE_VALID;
	frame.length = sizeof(frame);
	frame.function = RPC_FUNCTION_DCE_RM_INIT;
	frame.rpc_result = RPC_RESULT_PENDING;
	frame.rpc_result_private = RPC_RESULT_PENDING;
	frame.bInit = 0;

	memset(&msg, 0, sizeof(msg));
	msg.iface = DCE_CLIENT_IPC_TYPE_CPU_RM;
	msg.tx.data = &frame;
	msg.tx.size = sizeof(frame);
	msg.rx.data = &frame;
	msg.rx.size = sizeof(frame);

	fd = open(path, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return 1;
	}

	written = write(fd, &msg, sizeof(msg));
	if (written < 0) {
		fprintf(stderr, "write %s: %s\n", path, strerror(errno));
		close(fd);
		return 1;
	}
	close(fd);

	printf("proxy ret=%d rx.size=%zu rpc_result=0x%08x\n", msg.ret,
	       msg.rx.size, frame.rpc_result);

	if (msg.ret != 0 || frame.rpc_result != 0)
		return 1;
	return 0;
}
