/* NEON handler 正确性单元测试 (host 侧, 直接调 handler 核对 lane 数学) */
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "vm_types.h"
#include "vm_decode.h"
#include "vm_handlers/h_vec.h"
#include "vm_handlers/h_fp.h"

static int fails = 0;
#define CHECK(cond, msg) do { if(!(cond)){ printf("  FAIL: %s\n", msg); fails++; } } while(0)

static vm_ctx_t VM;
static u8 BC[64];
static void setq(int r, u64 lo, u64 hi){ VM.V[2*r]=lo; VM.V[2*r+1]=hi; }

int main(void){
  /* --- V3S: fadd 4S (q=1, esz=2, opc=32) : vd.4s = vn.4s + vm.4s --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  { vf32_u a0,a1,a2,a3,b0; a0.f=1.5f;a1.f=2.0f;a2.f=-3.25f;a3.f=10.0f;
    setq(1, ((u64)a0.u)|((u64)a1.u<<32), ((u64)a2.u)|((u64)a3.u<<32));
    b0.f=0.5f; setq(2, ((u64)b0.u)|((u64)b0.u<<32), ((u64)b0.u)|((u64)b0.u<<32)); }
  u8 p[]={OP_V3S,0,1,2, 2,0,32,1}; memcpy(BC,p,sizeof p);
  h_v3s(&VM);
  { vf32_u r0,r3; r0.u=(u32)VM.V[0]; r3.u=(u32)(VM.V[1]>>32);
    CHECK(fabsf(r0.f-2.0f)<1e-6, "fadd4s lane0=2.0");
    CHECK(fabsf(r3.f-10.5f)<1e-6, "fadd4s lane3=10.5"); }

  /* --- V3S: add 4S integer (opc=0, esz=2, q=1) --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  setq(1, (100ULL)|(200ULL<<32), (300ULL)|(400ULL<<32));
  setq(2, (1ULL)|(2ULL<<32), (3ULL)|(4ULL<<32));
  { u8 q[]={OP_V3S,0,1,2, 2,0,0,1}; memcpy(BC,q,sizeof q);} h_v3s(&VM);
  CHECK((u32)VM.V[0]==101 && (u32)(VM.V[0]>>32)==202, "add4s lane0/1");
  CHECK((u32)VM.V[1]==303 && (u32)(VM.V[1]>>32)==404, "add4s lane2/3");

  /* --- VFMA: fmla 2D (vd += vn*vm) esz=3 q=1 sub=0 --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  { vf64_u n0,n1,m0,m1,d0,d1; n0.d=2.0;n1.d=3.0;m0.d=5.0;m1.d=7.0;d0.d=1.0;d1.d=1.0;
    setq(1,n0.u,n1.u); setq(2,m0.u,m1.u); setq(0,d0.u,d1.u); }
  { u8 q[]={OP_VFMA,0,1,2,3,0,1}; memcpy(BC,q,sizeof q);} h_vfma(&VM);
  { vf64_u r0,r1; r0.u=VM.V[0]; r1.u=VM.V[1];
    CHECK(fabs(r0.d-11.0)<1e-9,"fmla2d lane0=1+2*5=11");
    CHECK(fabs(r1.d-22.0)<1e-9,"fmla2d lane1=1+3*7=22"); }

  /* --- V2S: fneg 2D (opc=32) --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  { vf64_u n0,n1; n0.d=3.5;n1.d=-4.0; setq(1,n0.u,n1.u); }
  { u8 q[]={OP_V2S,0,1,3,0,32,1}; memcpy(BC,q,sizeof q);} h_v2s(&VM);
  { vf64_u r0,r1; r0.u=VM.V[0]; r1.u=VM.V[1];
    CHECK(fabs(r0.d+3.5)<1e-9,"fneg2d lane0=-3.5");
    CHECK(fabs(r1.d-4.0)<1e-9,"fneg2d lane1=4.0"); }

  /* --- V2S: scvtf 2S (int->float, opc=40, esz=2, q=0) --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  setq(1, ((u64)(u32)(-5))|((u64)7<<32), 0);
  { u8 q[]={OP_V2S,0,1,2,0,40,0}; memcpy(BC,q,sizeof q);} h_v2s(&VM);
  { vf32_u r0,r1; r0.u=(u32)VM.V[0]; r1.u=(u32)(VM.V[0]>>32);
    CHECK(fabsf(r0.f+5.0f)<1e-6,"scvtf2s lane0=-5");
    CHECK(fabsf(r1.f-7.0f)<1e-6,"scvtf2s lane1=7");
    CHECK(VM.V[1]==0,"scvtf2s hi cleared"); }

  /* --- VDUPG: dup 4S from Rn --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  VM.R[3]=0xABCD;
  { u8 q[]={OP_VDUPG,0,3,2,1}; memcpy(BC,q,sizeof q);} h_vdupg(&VM);
  CHECK((u32)VM.V[0]==0xABCD && (u32)(VM.V[0]>>32)==0xABCD && (u32)VM.V[1]==0xABCD,"dupg4s");

  /* --- VUMOV: umov w, Vn.s[2] --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  setq(1, (11ULL)|(22ULL<<32), (33ULL)|(44ULL<<32));
  { u8 q[]={OP_VUMOV,5,1,2,2,0}; memcpy(BC,q,sizeof q);} h_vumov(&VM);
  CHECK(VM.R[5]==33,"umov s[2]=33");

  /* --- VEXT: ext q, idx=4 (bytes) --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  setq(1, 0x0706050403020100ULL, 0x0F0E0D0C0B0A0908ULL);
  setq(2, 0x1716151413121110ULL, 0x1F1E1D1C1B1A1918ULL);
  { u8 q[]={OP_VEXT,0,1,2,4,1}; memcpy(BC,q,sizeof q);} h_vext(&VM);
  /* 结果从 n 的 byte4 开始取 16 字节: n[4..15], m[0..3] */
  CHECK((VM.V[0]&0xFF)==0x04 && (u8)(VM.V[1]>>56)==0x13,"ext idx4");

  /* --- VPERM: zip1 4S --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  setq(1,(1ULL)|(2ULL<<32),(3ULL)|(4ULL<<32));
  setq(2,(10ULL)|(20ULL<<32),(30ULL)|(40ULL<<32));
  { u8 q[]={OP_VPERM,0,1,2,2,0,1}; memcpy(BC,q,sizeof q);} h_vperm(&VM);
  /* zip1.4s: d = n0,m0,n1,m1 = 1,10,2,20 */
  CHECK((u32)VM.V[0]==1 && (u32)(VM.V[0]>>32)==10 && (u32)VM.V[1]==2 && (u32)(VM.V[1]>>32)==20,"zip1_4s");

  /* --- FMADD scalar double: d = a + n*m --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  { vf64_u n,m,a; n.d=2.0;m.d=3.0;a.d=4.0; setq(1,n.u,0);setq(2,m.u,0);setq(3,a.u,0);}
  { u8 q[]={OP_FMADD,0,1,2,3,1,0}; memcpy(BC,q,sizeof q);} h_fmadd(&VM);
  { vf64_u r; r.u=VM.V[0]; CHECK(fabs(r.d-10.0)<1e-9,"fmadd d=4+2*3=10"); }
  /* FNMSUB (flags o1=1,o0=1): d = -a + n*m = -4+6 = 2 */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  { vf64_u n,m,a; n.d=2.0;m.d=3.0;a.d=4.0; setq(1,n.u,0);setq(2,m.u,0);setq(3,a.u,0);}
  { u8 q[]={OP_FMADD,0,1,2,3,1,3}; memcpy(BC,q,sizeof q);} h_fmadd(&VM);
  { vf64_u r; r.u=VM.V[0]; CHECK(fabs(r.d-2.0)<1e-9,"fnmsub d=-4+6=2"); }

  /* --- FCSEL: cond GT after fcmp --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  { vf64_u n,m; n.d=9.0;m.d=1.0; setq(1,n.u,0);setq(2,m.u,0);}
  VM.FL=0; /* GT: !Z&&!N → true */
  { u8 q[]={OP_FCSEL,0,1,2,12,1}; memcpy(BC,q,sizeof q);} h_fcsel(&VM);
  { vf64_u r; r.u=VM.V[0]; CHECK(fabs(r.d-9.0)<1e-9,"fcsel GT picks n"); }
  VM.FL=FL_SIGN; VM.pc=0; /* N=1 → GT false → picks m */
  h_fcsel(&VM);
  { vf64_u r; r.u=VM.V[0]; CHECK(fabs(r.d-1.0)<1e-9,"fcsel GT(N=1) picks m"); }

  /* --- VMOVI / VLDR / VSTR roundtrip --- */
  memset(&VM,0,sizeof VM); VM.bc=BC; VM.pc=0;
  { u8 q[18]={OP_VMOVI,0}; u64 lo=0x1122334455667788ULL,hi=0x99AABBCCDDEEFF00ULL;
    memcpy(q+2,&lo,8); memcpy(q+10,&hi,8); memcpy(BC,q,sizeof q);} h_vmovi(&VM);
  CHECK(VM.V[0]==0x1122334455667788ULL && VM.V[1]==0x99AABBCCDDEEFF00ULL,"vmovi");
  { static u8 mem[32]; memset(mem,0,sizeof mem); VM.R[4]=(u64)mem; VM.pc=0;
    u8 q[]={OP_VSTR,0,4,0,0,1}; memcpy(BC,q,sizeof q); h_vstr(&VM);
    VM.pc=0; u8 r[]={OP_VLDR,5,4,0,0,1}; memcpy(BC,r,sizeof r); h_vldr(&VM);
    CHECK(VM.V[10]==VM.V[0] && VM.V[11]==VM.V[1],"vstr/vldr q roundtrip"); }

  if(fails==0) printf("ALL NEON HANDLER TESTS PASSED\n");
  else printf("%d FAILURES\n", fails);
  return fails?1:0;
}
