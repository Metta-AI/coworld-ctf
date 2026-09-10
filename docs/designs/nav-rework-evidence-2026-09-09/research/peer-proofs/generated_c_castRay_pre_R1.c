N_LIB_PRIVATE N_NIMCALL(void, castRay__OOZsrcZshellZbody95nav_u1564)(tyObject_BodyNavSeatcolonObjectType___dVlj9cubxVHPnTADfinmDsw* seat_p0, tyObject_BodyMapcolonObjectType___4y9bFm44KMLHzM8rkjGTWaQ* map_p1, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ origin_p2, NF32* kernel_p3, NI kernel_p3Len_0, NI kernelRadius_p4, NI targetX_p5, NI targetY_p6) {
	NI dx_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_122;
	NI dy_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_123;
	NI nx_1;
	NI ny_1;
	NI stepX_1;
	NI stepY_1;
	NI x_1;
	NI y_1;
	NI ix_1;
	NI iy_1;
NIM_BOOL* nimErr_;
{nimErr_ = nimErrorFlag();
	if (nimSubInt(targetX_p5, origin_p2.Field0, &TM__fw0EGWK0CbR9aJ84zaF6cBg_122)) { raiseOverflow(); goto BeforeRet_;
	};
	dx_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_122);
	if (nimSubInt(targetY_p6, origin_p2.Field1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_123)) { raiseOverflow(); goto BeforeRet_;
	};
	dy_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_123);
	if (dx_1 == (IL64(-9223372036854775807) - IL64(1))){ raiseOverflow(); goto BeforeRet_;
	}
	nx_1 = (dx_1 > 0? (dx_1) : -(dx_1));
	if (dy_1 == (IL64(-9223372036854775807) - IL64(1))){ raiseOverflow(); goto BeforeRet_;
	}
	ny_1 = (dy_1 > 0? (dy_1) : -(dy_1));
	stepX_1 = cmp__system_u7067(dx_1, ((NI)0));
	stepY_1 = cmp__system_u7067(dy_1, ((NI)0));
	x_1 = origin_p2.Field0;
	y_1 = origin_p2.Field1;
	ix_1 = ((NI)0);
	iy_1 = ((NI)0);
	{
		while (1) {
			NIM_BOOL T3_;
			NI decision_1;
			NI TM__fw0EGWK0CbR9aJ84zaF6cBg_124;
			NI TM__fw0EGWK0CbR9aJ84zaF6cBg_125;
			NI TM__fw0EGWK0CbR9aJ84zaF6cBg_126;
			NI TM__fw0EGWK0CbR9aJ84zaF6cBg_127;
			NI TM__fw0EGWK0CbR9aJ84zaF6cBg_128;
			NI TM__fw0EGWK0CbR9aJ84zaF6cBg_129;
			NI TM__fw0EGWK0CbR9aJ84zaF6cBg_130;
			T3_ = (NIM_BOOL)0;
			T3_ = (ix_1 < nx_1);
			if (T3_) goto LA4_;
			T3_ = (iy_1 < ny_1);
LA4_: ;
			if (!T3_) goto LA2;
			if (nimMulInt(((NI)2), ix_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_124)) { raiseOverflow(); goto BeforeRet_;
			};
			if (nimAddInt(((NI)1), (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_124), &TM__fw0EGWK0CbR9aJ84zaF6cBg_125)) { raiseOverflow(); goto BeforeRet_;
			};
			if (nimMulInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_125), ny_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_126)) { raiseOverflow(); goto BeforeRet_;
			};
			if (nimMulInt(((NI)2), iy_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_127)) { raiseOverflow(); goto BeforeRet_;
			};
			if (nimAddInt(((NI)1), (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_127), &TM__fw0EGWK0CbR9aJ84zaF6cBg_128)) { raiseOverflow(); goto BeforeRet_;
			};
			if (nimMulInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_128), nx_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_129)) { raiseOverflow(); goto BeforeRet_;
			};
			if (nimSubInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_126), (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_129), &TM__fw0EGWK0CbR9aJ84zaF6cBg_130)) { raiseOverflow(); goto BeforeRet_;
			};
			decision_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_130);
			{
				NI sideX_1;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_131;
				NI sideY_1;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_132;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_133;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_134;
				if (!(decision_1 == ((NI)0))) goto LA7_;
				if (nimAddInt(x_1, stepX_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_131)) { raiseOverflow(); goto BeforeRet_;
				};
				sideX_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_131);
				if (nimAddInt(y_1, stepY_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_132)) { raiseOverflow(); goto BeforeRet_;
				};
				sideY_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_132);
				{
					NIM_BOOL T11_;
					T11_ = (NIM_BOOL)0;
					T11_ = sightCellBlocked__OOZsrcZshellZbody95nav_u1559(map_p1, sideX_1, y_1);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
					if (T11_) goto LA12_;
					T11_ = sightCellBlocked__OOZsrcZshellZbody95nav_u1559(map_p1, x_1, sideY_1);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
LA12_: ;
					if (!T11_) goto LA13_;
					goto LA1;
				}
LA13_: ;
				addVisibleCell__OOZsrcZshellZbody95nav_u1544(seat_p0, origin_p2, kernel_p3, kernel_p3Len_0, kernelRadius_p4, sideX_1, y_1);
				if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				addVisibleCell__OOZsrcZshellZbody95nav_u1544(seat_p0, origin_p2, kernel_p3, kernel_p3Len_0, kernelRadius_p4, x_1, sideY_1);
				if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				x_1 = sideX_1;
				y_1 = sideY_1;
				if (nimAddInt(ix_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_133)) { raiseOverflow(); goto BeforeRet_;
				};
				ix_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_133);
				if (nimAddInt(iy_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_134)) { raiseOverflow(); goto BeforeRet_;
				};
				iy_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_134);
			}
			goto LA5_;
LA7_: ;
			{
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_135;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_136;
				if (!(decision_1 < ((NI)0))) goto LA16_;
				if (nimAddInt(x_1, stepX_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_135)) { raiseOverflow(); goto BeforeRet_;
				};
				x_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_135);
				if (nimAddInt(ix_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_136)) { raiseOverflow(); goto BeforeRet_;
				};
				ix_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_136);
			}
			goto LA5_;
LA16_: ;
			{
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_137;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_138;
				if (nimAddInt(y_1, stepY_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_137)) { raiseOverflow(); goto BeforeRet_;
				};
				y_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_137);
				if (nimAddInt(iy_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_138)) { raiseOverflow(); goto BeforeRet_;
				};
				iy_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_138);
			}
LA5_: ;
			{
				NIM_BOOL T21_;
				T21_ = (NIM_BOOL)0;
				T21_ = sightCellBlocked__OOZsrcZshellZbody95nav_u1559(map_p1, x_1, y_1);
				if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				if (!T21_) goto LA22_;
				goto LA1;
			}
LA22_: ;
			addVisibleCell__OOZsrcZshellZbody95nav_u1544(seat_p0, origin_p2, kernel_p3, kernel_p3Len_0, kernelRadius_p4, x_1, y_1);
			if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
		} LA2: ;
	} LA1: ;
	}BeforeRet_: ;
}
